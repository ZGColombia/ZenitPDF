import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One markup layer, derived from the markups currently loaded.
public struct ZPDFLayerItem: Identifiable, Hashable, Sendable {

    /// The layer name, which is also its identity.
    public var id: String { name }
    /// The layer name.
    public let name: String
    /// How many markups sit on it.
    public let markupCount: Int

    /// Creates a layer row.
    public init(name: String, markupCount: Int) {
        self.name = name
        self.markupCount = markupCount
    }
}

/// The Navigator sidebar: Pages, Layers, Project Zones, Search.
public struct NavigatorSidebar: View {

    private let environment: ProjectShellEnvironment
    @Bindable private var panelState: ShellPanelState

    /// Creates the sidebar.
    public init(
        environment: ProjectShellEnvironment,
        panelState: ShellPanelState
    ) {
        self.environment = environment
        self._panelState = Bindable(panelState)
    }

    /// The 2026-09-23 mockup's left column: the tab strip on the window chrome, then one rounded
    /// panel with a hairline outline holding the section's content.
    public var body: some View {
        VStack(spacing: NavigatorStyle.gutter) {
            switcherRow
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZPDFColor.color(NavigatorStyle.panelFill))
                .clipShape(RoundedRectangle(cornerRadius: NavigatorStyle.panelRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: NavigatorStyle.panelRadius, style: .continuous)
                        .strokeBorder(ZPDFColor.color(NavigatorStyle.panelEdge), lineWidth: ZPDFStroke.regular)
                        .allowsHitTesting(false)
                }
        }
        .padding(NavigatorStyle.gutter)
        .background(ZPDFColor.color(NavigatorStyle.chromeFill))
        // The standard escape path: Escape on the pane hides it, same as its close control.
        .onExitCommand { environment.perform(.toggleNavigator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Navigator",
            comment: "Accessibility label for the navigator sidebar"
        )))
    }

    /// The sections worth offering: Drawings only once there is more than one drawing to list.
    /// A list of every open drawing with one row in it teaches people not to look at it.
    private var offeredSections: [NavigatorSection] {
        Self.offeredSections(forOpenDrawings: environment.document.tabs.count)
    }

    /// The switcher's segments: the mockup's four, `Pages · Layers · Zones · Search`.
    /// Open Drawings stays a section the Navigator can show — offered by
    /// ``offeredSections(forOpenDrawings:)`` — but it is reached from the file header's ⋯ menu,
    /// not a fifth segment: five segments forced the labels down to ~10 pt in the strip.
    static let segments: [NavigatorSection] = [.pages, .layers, .zones, .search]

    /// The rule behind ``offeredSections``, as a function of the open-drawing count.
    ///
    /// Static and value-only so a test can assert *this* rule rather than restate it. Three
    /// Navigator tests used to carry their own copy of it, which meant they agreed with each
    /// other and could stop agreeing with the sidebar without a single failure (CR-120).
    static func offeredSections(forOpenDrawings count: Int) -> [NavigatorSection] {
        count > 1
            ? NavigatorSection.allCases
            : NavigatorSection.allCases.filter { $0 != .drawings }
    }

    /// The section to show, given the one a stored layout asked for and the ones on offer.
    ///
    /// Returns `nil` when the stored choice is fine. Split out from the repair itself so the
    /// rule is assertable without a view tree.
    static func repairedSection(
        for stored: NavigatorSection,
        offered: [NavigatorSection]
    ) -> NavigatorSection? {
        offered.contains(stored) ? nil : .pages
    }

    /// The section switcher plus the pane's visible close control: every panel can be closed
    /// from its own header.
    private var switcherRow: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            // Labeled tabs, the active one filled and underlined — the mockup's switcher,
            // never bare icons.
            NavigatorSwitcher(
                selection: $panelState.navigatorSection,
                sections: Self.segments
            )
            // `initial: true` — the repair has to run on the FIRST evaluation, not only on a
            // later change. The Drawings section is withheld while one document is open, and a
            // stored layout can still point at it: restoring `.drawings` with one drawing open
            // left the switcher with no segment for what it was showing, the pane blank, and
            // the arrow keys dead, because `offeredSections` never *changed* after launch and
            // the repair never fired (CR-111).
            .onChange(of: offeredSections, initial: true) { _, offered in
                if let repaired = Self.repairedSection(
                    for: panelState.navigatorSection,
                    offered: offered
                ) {
                    panelState.navigatorSection = repaired
                }
            }
            // The mockup's strip has no close control; every panel needs one on its own
            // header, so it stays — small, trailing, quiet.
            ZPDFToolbarButton(
                glyph: .symbol(.close),
                title: NSLocalizedString("Close Navigator", comment: "Navigator header close control"),
                keyboardHint: environment.commands
                    .command(.toggleNavigator)?.binding?.displayString
            ) {
                environment.perform(.toggleNavigator)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panelState.navigatorSection {
        case .drawings:
            VStack(spacing: 0) {
                NavigatorDrawingsHeader(panelState: panelState)
                NavigatorDrawingsList(environment: environment)
            }
        case .pages: NavigatorPagesList(environment: environment, panelState: panelState)
        case .layers: NavigatorLayersList(environment: environment)
        case .zones: NavigatorZonesList(environment: environment)
        case .search: NavigatorSearchPage(environment: environment, panelState: panelState)
        }
    }
}

// MARK: - Pages

/// The Pages navigator per the 2026-09-23 mockup: each open drawing's header with its ⋯ menu
/// (LT3-11: every open drawing is listed), then, for the drawing on screen, one card per page — thumbnail left, page number and a second line right, a ⋯ menu —
/// with the page on screen framed in the accent.
///
/// The layer outline that used to sit under the page column is gone: the mockup gives the
/// whole panel to the cards, and every control the outline offered is on the Layers tab, which
/// shares the same row views and the same visibility model (IM-030, CR-112).
struct NavigatorPagesList: View {

    let environment: ProjectShellEnvironment
    /// Where "Show Open Drawings" switches the Navigator. Optional so the list can be built on
    /// its own in a preview.
    var panelState: ShellPanelState?

    /// Whether the trailing (append) drop zone is targeted.
    @State private var isEndDropTargeted = false
    /// The page cards a drawing is dragged over while each stands in for the column (a Quick PDF,
    /// V-044): the column's hint shows over them too.
    @State private var columnDropCards: Set<PageDescriptor.ID> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drawings the person folded. The front drawing is unfolded again whenever it comes to
    /// the front, so switching drawings always shows the pages of the one on screen.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let pages = environment.document.pages
        let tabs = environment.document.tabs
        if pages.isEmpty && tabs.isEmpty {
            // The next step, not just a statement (IM-217): the same Open command the File
            // menu and the tab strip's `+` run.
            ZPDFEmptyState(
                glyph: .symbol(.pages),
                title: NSLocalizedString("No pages", comment: "Pages navigator empty state title"),
                message: NSLocalizedString(
                    "Open a drawing to browse its pages here.",
                    comment: "Pages navigator empty state message"
                ),
                actionTitle: Self.emptyStateActionTitle,
                action: { environment.perform(.openDocument) }
            )
            .navigatorDropTarget(environment: environment, insertionIndex: 0, isTargeted: $isEndDropTargeted)
        } else {
            // LT3-11: every open drawing has a section — header, then (for the one on screen)
            // its page cards — so N open drawings are N visible sections, in tab order.
            let sections = NavigatorDrawingSection.sections(
                tabs: tabs,
                activeID: environment.document.activeTabID,
                collapsed: collapsed
            )
            VStack(spacing: 0) {
                // NL-DOCS-06: the mockup's cards, or a dense index of sheets by discipline.
                Picker(Self.modeLabel, selection: $mode) {
                    ForEach(NavigatorPagesMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, ZPDFSpacing.s)
                .padding(.top, ZPDFSpacing.xs)
                .accessibilityLabel(Text(Self.modeLabel))
                if mode == .index {
                    NavigatorSheetIndexView(environment: environment)
                } else {
                    cards(sections: sections, pages: pages)
                }
            }
        }
    }

    /// How the Pages tab shows the drawing: cards or index.
    @State private var mode: NavigatorPagesMode = .cards

    static var modeLabel: String {
        NSLocalizedString("Pages view", comment: "Accessibility label of the Pages tab's Cards / Index switch")
    }

    @ViewBuilder
    private func cards(sections: [NavigatorDrawingSection], pages: [PageDescriptor]) -> some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if sections.isEmpty {
                            // Pages without a tab summary (a preview): the old single header.
                            NavigatorFileHeader(environment: environment, panelState: panelState)
                            pageRows(pages)
                        }
                        ForEach(sections) { section in
                            NavigatorDrawingSectionHeader(
                                environment: environment,
                                panelState: panelState,
                                section: section,
                                onClick: handle
                            )
                            .id(section.id)
                            if section.isExpanded {
                                pageRows(pages)
                            }
                        }
                    }
                    .padding(.horizontal, ZPDFSpacing.s)
                    .padding(.bottom, ZPDFSpacing.s)
                }
                // The column follows the page on screen (IM-124). ⌘↓, the status bar's
                // page field and a search hit all move the canvas without touching this
                // list, and in a 23-sheet set the lit thumbnail scrolled out of sight.
                .onAppear { reveal(environment.document.currentPageID, in: proxy, animated: false) }
                .onChange(of: environment.document.currentPageID) { _, pageID in
                    reveal(pageID, in: proxy, animated: true)
                }
                .onChange(of: environment.document.activeTabID) { _, active in
                    guard let active else { return }
                    collapsed.remove(active)
                }
            }
            // The whole column takes a drop, and says what it will do.
            .navigatorDropTarget(
                environment: environment,
                insertionIndex: pages.count,
                isTargeted: $isEndDropTargeted
            )
            .overlay(alignment: .top) {
                if NavigatorDropPolicy.showsColumnHint(columnTargeted: isEndDropTargeted, cardsTargeted: columnDropCards) {
                    Text(NavigatorDropPolicy.dropHint(addsToProject: environment.navigatorDropAddsToProject))
                        .zpdfText(.control, .textPrimary)
                        .padding(.horizontal, ZPDFSpacing.m)
                        .padding(.vertical, ZPDFSpacing.xs)
                        .background(Capsule().fill(ZPDFColor.color(.elevated)))
                        .overlay(Capsule().strokeBorder(ZPDFColor.color(NavigatorStyle.stateLine), lineWidth: ZPDFStroke.regular))
                        .padding(.top, ZPDFSpacing.s)
                        .allowsHitTesting(false)
                        .accessibilityLabel(Text(NavigatorDropPolicy.dropHint(addsToProject: environment.navigatorDropAddsToProject)))
                }
            }
    }

    /// The front drawing's page cards.
    @ViewBuilder
    private func pageRows(_ pages: [PageDescriptor]) -> some View {
        let selected = Set(environment.document.selectedPageIDs)
        let current = environment.document.currentPageID
        let highlighted = pages.map { $0.id == current || selected.contains($0.id) }
        ForEach(Array(pages.enumerated()), id: \.element.id) { position, page in
            NavigatorPageRow(
                environment: environment,
                page: page,
                pageCount: pages.count,
                insertionIndex: position,
                isCurrent: page.id == current,
                isSelected: selected.contains(page.id),
                showsSeparator: Self.showsSeparator(
                    after: position,
                    highlighted: highlighted
                ),
                onColumnDropTargeted: { id, targeted in
                    if targeted { columnDropCards.insert(id) } else { columnDropCards.remove(id) }
                }
            )
            .id(page.id)
        }
        // U-044: the strip under the last card, the one drop that lands a sheet last. A card
        // only ever takes a sheet before itself, so without it no drag reached the end.
        NavigatorPageEndDropZone(environment: environment, position: pages.count)
        // Sheets removed from the set, each with Restore (NL-DOCS-07).
        NavigatorRemovedSheetsSection(environment: environment)
    }

    /// A drawing header was clicked: a back drawing comes to the front through the tab
    /// strip's own hook (so the window switches, not just the summary); the front one folds.
    private func handle(_ click: NavigatorDrawingSection.HeaderClick) {
        switch click {
        case let .switchTo(id):
            collapsed.remove(id)
            environment.tabBar.onSelect?(id)
        case let .toggle(id):
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    /// Whether the hairline under the card at `position` is drawn: between two cards that both
    /// lie flat on the panel, never under the last card and never touching a framed card — a
    /// highlighted card is its own frame, and a rule running into its border reads as a glitch.
    static func showsSeparator(after position: Int, highlighted: [Bool]) -> Bool {
        let next = position + 1
        guard highlighted.indices.contains(position), highlighted.indices.contains(next) else {
            return false
        }
        return !highlighted[position] && !highlighted[next]
    }

    /// The empty state's one action.
    static var emptyStateActionTitle: String {
        NSLocalizedString("Open…", comment: "Pages navigator empty state action: open a drawing")
    }

    /// Scrolls the current page's thumbnail into view — without travel under Reduce Motion.
    private func reveal(_ pageID: PageDescriptor.ID?, in proxy: ScrollViewProxy, animated: Bool) {
        guard let pageID else { return }
        let animation = animated
            ? ZPDFMotion.animation(.standard, reduceMotion: reduceMotion)
            : nil
        withAnimation(animation) {
            proxy.scrollTo(pageID, anchor: nil)
        }
    }
}

/// One page row: the thumbnail button, its ⋯ menu, and drag-to-reorder within the set
/// (NL-DOCS-07): a card dragged onto another card moves there, with the selection when it was
/// part of one. One undo step, through ``ProjectShellEnvironment/onMovePages``.
struct NavigatorPageRow: View {

    let environment: ProjectShellEnvironment
    let page: PageDescriptor
    let pageCount: Int
    let insertionIndex: Int
    let isCurrent: Bool
    /// Whether this page is in the Navigator's selection, which is not the same thing as
    /// being the page on screen: Command-clicking three thumbnails selects three and shows
    /// the last, and the scoped batch apply acts on all three.
    let isSelected: Bool
    /// Whether the hairline under this card is drawn (see ``NavigatorPagesList/showsSeparator(after:highlighted:)``).
    var showsSeparator: Bool = false
    /// Reports a drawing dragged over (or off) this card while the card stands in for the column
    /// — a Quick PDF, where the drop opens as its own drawing — so the column shows its hint.
    var onColumnDropTargeted: ((PageDescriptor.ID, Bool) -> Void)?

    @State private var isReorderTargeted = false
    @State private var isFileDropTargeted = false
    @State private var isNaming = false

    var body: some View {
        VStack(spacing: 0) {
            decoratedCard
            if isNaming, let name = environment.onNameSheet {
                NavigatorSheetNameEditor(
                    page: page,
                    onCommit: { number, title in
                        name(page.id, number, title)
                        isNaming = false
                    },
                    onCancel: { isNaming = false }
                )
            }
        }
    }

    private var decoratedCard: some View {
        card
            // A drawing dropped on a card is the card's to take, in both modes (V-044). SwiftUI
            // hands a drop to the innermost destination that accepts one of the drag's types and
            // does not pass a refusal up, so the card must never claim a drop and say no:
            // * in a project, the drawing joins before this card (NL-DOCS-04), under the line;
            // * in a Quick PDF, it opens as its own drawing (NL-DOCS-03) exactly as the column
            //   would, and the column's hint shows.
            // The URL destination is the innermost one on the card, so a file drag that also
            // carries plain text reaches it before the page-reorder destination below, which
            // only takes a card's private text payload and refuses everything else.
            .dropDestination(for: URL.self) { urls, _ in
                NavigatorDropPolicy.dropOnCard(urls, insertionIndex: insertionIndex, pageCount: pageCount, in: environment)
            } isTargeted: { targeted in
                let active = targeted && environment.onNavigatorDropFiles != nil
                let beforeCard = NavigatorDropPolicy.cardDrawsInsertionLine(addsToProject: environment.navigatorDropAddsToProject)
                isFileDropTargeted = active && beforeCard
                onColumnDropTargeted?(page.id, active && !beforeCard)
            }
            .draggable(NavigatorPageDrag.payload(for: page.id)) {
                Text(NavigatorPageCard.subtitle(for: page, usesMetric: NavigatorPageCard.localeUsesMetric))
                    .zpdfText(.control, .textPrimary)
                    .padding(ZPDFSpacing.s)
            }
            .dropDestination(for: String.self) { payloads, _ in
                NavigatorPageDrag.drop(payloads, at: insertionIndex, in: environment)
            } isTargeted: { targeted in
                isReorderTargeted = targeted && environment.onMovePages != nil
            }
            .overlay(alignment: .top) {
                if isReorderTargeted || isFileDropTargeted {
                    // Where a dragged sheet — or a dropped drawing's sheets — lands: before this card.
                    Rectangle()
                        .fill(ZPDFColor.color(NavigatorStyle.stateLine))
                        .frame(height: 2)
                        .offset(y: -1)
                        .accessibilityHidden(true)
                }
            }
            // The ⋯ menu sits on the card's bottom-trailing corner, as in the mockup. It is a
            // sibling of the card's button, not inside its label: a menu inside a button would
            // swallow the page click or be swallowed by it.
            .overlay(alignment: .bottomTrailing) {
                NavigatorMoreMenu(
                    accessibilityLabel: NavigatorPageAction.menuLabel(for: page, position: insertionIndex),
                    hint: NavigatorPageAction.menuHint(for: page, position: insertionIndex)
                ) {
                    NavigatorPageActionItems(
                        environment: environment, pageID: page.id, isSelected: isSelected,
                        onNameSheet: { isNaming = true }
                    )
                }
                .padding(ZPDFSpacing.s)
            }
            // The same items on a right-click, for the hand that never looks for the ⋯.
            .contextMenu {
                NavigatorPageActionItems(
                    environment: environment, pageID: page.id, isSelected: isSelected,
                    onNameSheet: { isNaming = true }
                )
            }
            .overlay(alignment: .bottom) {
                if showsSeparator {
                    ZPDFHairlineDivider(
                        axis: .horizontal,
                        leadingInset: NavigatorStyle.cardPadding,
                        trailingInset: NavigatorStyle.cardPadding,
                        token: NavigatorStyle.hairline
                    )
                }
            }
    }

    private var card: some View {
        NavigatorPageThumbnail(
            page: page,
            pageCount: pageCount,
            position: insertionIndex,
            isCurrent: isCurrent,
            isSelected: isSelected,
            thumbnails: environment.navigatorThumbnails,
            isUnscaled: environment.unscaledPageIDs.contains(page.id)
        ) {
            // Modifiers are read at the moment of the click. SwiftUI's `Button` does not
            // carry them, and the alternative — a gesture recogniser per thumbnail — would
            // cost the row its keyboard focus and its accessibility traits.
            let flags = NSEvent.modifierFlags
            // Through the environment, not straight to the presenter: the page-scoped panels
            // (Scale Regions) are told the page moved, which a direct call never did (BH-296).
            environment.selectPage(
                id: page.id,
                mode: PageSelectionMode.forModifiers(
                    command: flags.contains(.command),
                    shift: flags.contains(.shift)
                )
            )
        }
        // In a Quick PDF a dropped drawing opens as its own (NL-DOCS-03), so no insertion line is
        // drawn; in a project the card takes the drop and the line is true (NL-DOCS-04, see
        // `decoratedCard`).
    }
}

/// A page card's drag payload: a private text form, so a card can only land on another card
/// and a stray text drop from elsewhere is refused.
enum NavigatorPageDrag {
    static let prefix = "zenit-page:"

    static func payload(for id: PageDescriptor.ID) -> String { prefix + id.uuidString }

    static func pageID(in payload: String) -> PageDescriptor.ID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }

    /// The block's new first position when dropped on the card at `position`: it lands before
    /// that card, counted in the set without the block. `position == pages.count` is the strip
    /// under the last card, which lands it last.
    static func target(dropOn position: Int, block: [PageDescriptor.ID], pages: [PageDescriptor]) -> Int {
        let moving = Set(block)
        return pages.prefix(position).filter { !moving.contains($0.id) }.count
    }

    /// Where a drop at `position` moves the block, or `nil` when it would change nothing: a drop
    /// on the block itself, or on the card just after it (U-044 — that drop used to report
    /// success and leave the order as it was).
    static func destination(dropOn position: Int, block: [PageDescriptor.ID], pages: [PageDescriptor]) -> Int? {
        guard !block.isEmpty else { return nil }
        if pages.indices.contains(position), block.contains(pages[position].id) { return nil }
        let target = target(dropOn: position, block: block, pages: pages)
        let order = pages.map(\.id)
        guard NavigatorArrangeAction.changesOrder(order, moving: block, to: target) else { return nil }
        return target
    }

    /// A page card's payload dropped at `position` — on a card, or on the strip under the last
    /// one. Moves the dragged card, with the selection when it is part of one, as one step
    /// through ``ProjectShellEnvironment/onMovePages``; answers whether anything moved, so a
    /// drop that changes nothing is refused rather than accepted in silence.
    @MainActor
    static func drop(_ payloads: [String], at position: Int, in environment: ProjectShellEnvironment) -> Bool {
        guard let move = environment.onMovePages,
              let dragged = payloads.lazy.compactMap(pageID(in:)).first
        else { return false }
        let pages = environment.document.pages
        let block = NavigatorArrangeAction.block(
            for: dragged, selection: environment.document.selectedPageIDs, pages: pages
        )
        guard let target = destination(dropOn: position, block: block, pages: pages) else { return false }
        move(block, target)
        return true
    }
}

/// The strip under the last page card (U-044): a dragged card dropped here moves last, and the
/// line at its top says so. It takes page cards only; a dropped drawing still reaches the
/// column's own target, which appends it with the column's hint. Keyboard and VoiceOver users
/// have the card's Move to Bottom, so the strip itself is hidden from accessibility.
private struct NavigatorPageEndDropZone: View {

    let environment: ProjectShellEnvironment
    /// `pages.count`: the append position.
    let position: Int

    @State private var isReorderTargeted = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: ZPDFSpacing.Control.minimumHitTarget)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payloads, _ in
                NavigatorPageDrag.drop(payloads, at: position, in: environment)
            } isTargeted: { targeted in
                isReorderTargeted = targeted && environment.onMovePages != nil
            }
            .overlay(alignment: .top) {
                if isReorderTargeted {
                    Rectangle()
                        .fill(ZPDFColor.color(NavigatorStyle.stateLine))
                        .frame(height: 2)
                        .offset(y: -1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The Navigator's drop policy, separated from the views so it is testable: which of the
/// dragged files the Navigator can open, in Finder order.
enum NavigatorDropPolicy {

    /// The extensions this application opens: PDFs, projects, and scans or photos of sheets,
    /// which become PDF drawings (NL-PLAT-04). Everything else is refused during the drag.
    static let acceptedExtensions: Set<String> = ["pdf", "zpdfproj", "tif", "tiff", "jpg", "jpeg", "png", "heic", "heif", "dxf", "dwg"]

    /// What the column says while a drawing is dragged over it: in a project the drawing joins
    /// it (NL-DOCS-04); in a Quick PDF it opens as one of its own (NL-DOCS-03).
    static func dropHint(addsToProject: Bool) -> String {
        addsToProject
            ? NSLocalizedString(
                "Adds the drawing to this project",
                comment: "Navigator page column of a project: dropping a PDF adds it to the project"
            )
            : NSLocalizedString(
                "Opens as a separate drawing",
                comment: "Navigator page column: what dropping a PDF on it will do"
            )
    }

    /// The droppable subset of a drag's files, order preserved.
    static func acceptedURLs(_ urls: [URL]) -> [URL] {
        urls.filter { acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Whether a drawing dragged over a page card lands before that card, under its insertion
    /// line: in a project (NL-DOCS-04). In a Quick PDF the card stands in for the column — the
    /// drawing opens as its own and the column's hint shows (V-044).
    static func cardDrawsInsertionLine(addsToProject: Bool) -> Bool { addsToProject }

    /// Where a drawing dropped on the card at `cardPosition` is inserted: before the card in a
    /// project, at the column's append position in a Quick PDF — the index the column's own
    /// destination passes, so a card and a gap between cards do the same thing (V-044).
    static func cardDropIndex(addsToProject: Bool, cardPosition: Int, pageCount: Int) -> Int {
        addsToProject ? cardPosition : pageCount
    }

    /// A drawing dropped on a page card. Answers whether anything was taken; a drag with no file
    /// the Navigator opens is refused, as the column refuses it.
    @MainActor
    static func dropOnCard(_ urls: [URL], insertionIndex: Int, pageCount: Int, in environment: ProjectShellEnvironment) -> Bool {
        let accepted = acceptedURLs(urls)
        guard !accepted.isEmpty else { return false }
        let index = cardDropIndex(
            addsToProject: environment.navigatorDropAddsToProject,
            cardPosition: insertionIndex,
            pageCount: pageCount
        )
        return environment.onNavigatorDropFiles?(accepted, index) ?? false
    }

    /// Whether the column's hint shows: over the column itself, or over a card standing in for it.
    static func showsColumnHint(columnTargeted: Bool, cardsTargeted: Set<PageDescriptor.ID>) -> Bool {
        columnTargeted || !cardsTargeted.isEmpty
    }
}

private extension View {

    /// Makes a view a Navigator drop target that inserts at `insertionIndex`.
    func navigatorDropTarget(
        environment: ProjectShellEnvironment,
        insertionIndex: Int,
        isTargeted: Binding<Bool>
    ) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let accepted = NavigatorDropPolicy.acceptedURLs(urls)
            guard !accepted.isEmpty else { return false }
            return environment.onNavigatorDropFiles?(accepted, insertionIndex) ?? false
        } isTargeted: { targeted in
            isTargeted.wrappedValue = targeted && environment.onNavigatorDropFiles != nil
        }
    }
}

/// One page card, per the 2026-09-23 mockup: the sheet on the left, the page number and a
/// second line on the right. The page on screen is raised and framed in the accent; a page in
/// the Navigator's selection gets a lighter frame; hover is a faint wash. The ⋯ menu is laid
/// over the card by ``NavigatorPageRow``.
struct NavigatorPageThumbnail: View {

    let page: PageDescriptor
    let pageCount: Int
    /// The card's place in the set (ADR-0022), which the first line shows.
    var position: Int? = nil
    let isCurrent: Bool
    /// Whether the page is part of the Navigator's selection.
    let isSelected: Bool
    /// Where the real page renders come from. `nil` provider means placeholder-only.
    let thumbnails: NavigatorThumbnailLoader
    /// Whether the sheet has no scale of its own: the card says "No scale" (NL-MEASURE-02).
    var isUnscaled: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = NavigatorPageCard.appearance(isCurrent: isCurrent, isSelected: isSelected, isHovered: isHovered)
        let shape = RoundedRectangle(cornerRadius: NavigatorStyle.cardRadius, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: ZPDFSpacing.l) {
                sheet
                VStack(alignment: .leading, spacing: 2) {
                    // Page number ~13 pt regular, sheet name ~12 pt, both primary text; the
                    // sheet-size fallback is not a name and reads as secondary text.
                    Text(NavigatorPageCard.title(for: page, position: position))
                        .zpdfText(.rowLabel, .textPrimary)
                        .lineLimit(1)
                    Text(NavigatorPageCard.subtitle(for: page, usesMetric: NavigatorPageCard.localeUsesMetric))
                        .zpdfText(.control, NavigatorPageCard.sheetName(for: page) == nil ? .textSecondary : .textPrimary)
                        .lineLimit(NavigatorPageCard.subtitleLineLimit(for: page))
                        // LT3-04: the sheet size ("A1 · 841 × 594 mm") stays on one line,
                        // shrinking slightly before it would wrap; a sheet name may take two.
                        .minimumScaleFactor(NavigatorPageCard.sheetName(for: page) == nil ? 0.8 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if isUnscaled { NavigatorNoScaleBadge() }
                }
                .padding(.top, 2)
                // Room for the ⋯ menu the row lays over the bottom-trailing corner.
                .padding(.trailing, ZPDFSpacing.Control.minimumHitTarget / 2)
                Spacer(minLength: 0)
            }
            .padding(NavigatorStyle.cardPadding)
            .frame(maxWidth: .infinity, minHeight: NavigatorStyle.cardHeight, alignment: .leading)
            .background {
                ZStack {
                    if let base = look.base { shape.fill(ZPDFColor.color(base)) }
                    if let tint = look.tint { shape.fill(ZPDFColor.color(tint).opacity(look.tintOpacity)) }
                }
            }
            .overlay {
                if let border = look.border {
                    shape.strokeBorder(ZPDFColor.color(border), lineWidth: look.borderWidth)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ZPDFMotion.animation(.micro, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .zpdfAnimation(NavigatorStyle.motion, value: look)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: NavigatorStyle.cardRadius)
        .help(NavigatorPageCard.accessibilityLabel(for: page, pageCount: pageCount, position: position))
        .accessibilityLabel(Text(NavigatorPageCard.accessibilityLabel(for: page, pageCount: pageCount, position: position, isUnscaled: isUnscaled)))
        .accessibilityValue(Text(Self.stateText(isCurrent: isCurrent, isSelected: isSelected)))
        .accessibilityAddTraits((isCurrent || isSelected) ? [.isSelected, .isButton] : .isButton)
        // Placeholder-then-fill: the request runs off the row's lifetime; when the image
        // lands the loader's observation re-renders exactly this row.
        // Keyed on the provider revision as well as the page (IM-125, BH-816): a provider
        // installed after the column first rendered — or a flush through `invalidate()` —
        // re-runs the request, exactly as the Drawings rows already do (LT-1).
        .task(id: NavigatorThumbnailTaskKey(subject: page.id, providerRevision: thumbnails.providerRevision)) {
            await thumbnails.request(pageID: page.id, pageIndex: page.index)
        }
    }

    /// What VoiceOver says after the page's name.
    ///
    /// Three visual states, and only two of them were ever spoken. The page on screen and a
    /// page merely in the Navigator's selection both carried the `.isSelected` trait and
    /// nothing else, differing on screen by half a point of border width and by a badge that
    /// is `accessibilityHidden` — so a screen-reader user could not tell which sheet the
    /// canvas was actually showing (CR-119). Words, not a border weight.
    ///
    /// Static and value-only so the mapping is testable without a view tree.
    static func stateText(isCurrent: Bool, isSelected: Bool) -> String {
        if isCurrent {
            return NSLocalizedString(
                "Showing",
                comment: "Accessibility value: this page is the one on the canvas"
            )
        }
        if isSelected {
            return NSLocalizedString(
                "Selected",
                comment: "Accessibility value: this page is in the Navigator's selection"
            )
        }
        return ""
    }

    /// The sheet's size inside the card's thumbnail box: the page's own proportions, fitted.
    /// Static so the fit is testable; an extreme strip is clamped so it never draws as a line.
    static func sheetSize(for page: PageDescriptor, in box: CGSize = NavigatorStyle.thumbnailSize) -> CGSize {
        // The sheet as it is shown: turned and cropped (NL-DOCS-07/16).
        let size = page.viewSize
        let raw = size.height > 0 ? size.width / size.height : 1
        let ratio = min(2.2, max(0.45, raw))
        let boxRatio = box.width / box.height
        return ratio >= boxRatio
            ? CGSize(width: box.width, height: (box.width / ratio).rounded())
            : CGSize(width: (box.height * ratio).rounded(), height: box.height)
    }

    /// The page sheet: the real render when it has arrived, the proportioned placeholder
    /// until then — so the column keeps its rhythm.
    private var sheet: some View {
        let fitted = Self.sheetSize(for: page)
        // Turned and cropped like the sheet on the canvas (NL-DOCS-07/16).
        let image = thumbnails.image(for: page)
        let paper = RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
        return paper
            // The sheet reads as paper against the dark panel, like the canvas sheet — also
            // before its render lands (design QA): a paper-toned sheet with a faint page glyph
            // reads as a page on its way, and a render that fails stays that, never an alert.
            .fill(NavigatorStyle.paper)
            .frame(width: fitted.width, height: fitted.height)
            .overlay {
                if image == nil {
                    // Pinned to the light variant: the glyph sits on paper, which is light in
                    // every appearance.
                    ZPDFGlyphView(.symbol(.pages), size: ZPDFSpacing.Control.iconLarge)
                        .foregroundStyle(ZPDFColor.color(.textTertiary, variant: .light))
                }
            }
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(paper)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                paper.strokeBorder(ZPDFColor.color(NavigatorStyle.hairline), lineWidth: ZPDFStroke.regular)
            }
            .frame(width: NavigatorStyle.thumbnailSize.width, height: NavigatorStyle.thumbnailSize.height)
            .accessibilityHidden(true)
    }
}

/// One document (PDF optional-content) layer row on the Layers page (the outline that once
/// shared it left the Pages tab with the 2026-09-23 mockup), offering what IM-030 asked for: the checkbox reports into the real
/// per-document visibility set through ``NavigatorLayerListModel`` and flips only when the app
/// tier applies the new effective state; the Feature 30 "Measuring here" marker; a labelled lock;
/// and the measure-lock context menu.
struct NavigatorDocumentLayerRow: View {

    let environment: ProjectShellEnvironment
    let row: NavigatorLayerRow
    /// Whether the visible "Visible / Hidden" word is drawn (the Layers page has room for it).
    let showsStateText: Bool

    var body: some View {
        let isMeasuringHere = environment.navigatorLayers.measureLockLayerID == row.id
        HStack(spacing: ZPDFSpacing.s) {
            Toggle(isOn: Binding(
                get: { row.isVisible },
                set: { environment.navigatorLayers.setVisible($0, layerID: row.id) }
            )) {
                Text(row.name).zpdfText(.body, .textPrimary).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(NavigatorLayerLabel.documentLayer(row.name)))
            .accessibilityValue(Text(NavigatorLayerLabel.visibility(row.isVisible)))
            Spacer(minLength: 0)
            if isMeasuringHere {
                // Feature 30's marker: text, not colour, so the lock is never silent.
                Text(NavigatorLayerLabel.measuringHere)
                    .zpdfText(.caption, .textSecondary)
            }
            if row.isLocked {
                ZPDFGlyphView(.symbol(.lock), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .help(NavigatorLayerLabel.lockedHelp)
                    .accessibilityLabel(Text(NavigatorLayerLabel.locked))
            }
            if showsStateText {
                Text(NavigatorLayerLabel.visibility(row.isVisible))
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
        .contextMenu {
            Button(NavigatorLayerLabel.measureLockMenuTitle(isMeasuringHere: isMeasuringHere)) {
                environment.navigatorLayers.setMeasureLock(isMeasuringHere ? nil : row.id)
            }
        }
    }
}

/// One markup layer row: the shared visibility checkbox, and — on the Layers page — the markup
/// count and the visible state word.
struct NavigatorMarkupLayerRow: View {

    let environment: ProjectShellEnvironment
    let layer: ZPDFLayerItem
    /// Whether the count and the state word are drawn.
    let showsDetails: Bool

    var body: some View {
        let layers = environment.navigatorLayers
        let isVisible = layers.isMarkupLayerVisible(layer.name)
        Toggle(isOn: Binding(
            get: { layers.isMarkupLayerVisible(layer.name) },
            set: { layers.setMarkupLayerVisible($0, layer: layer.name) }
        )) {
            HStack(spacing: ZPDFSpacing.m) {
                Text(layer.name).zpdfText(.body, .textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if showsDetails {
                    Text(layer.markupCount.formatted())
                        .zpdfText(.monoNumeric.withSize(11), .textSecondary)
                    Text(NavigatorLayerLabel.visibility(isVisible))
                        .zpdfText(.caption, .textSecondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
        .accessibilityLabel(Text(NavigatorLayerLabel.markupLayer(layer.name)))
        .accessibilityValue(Text(NavigatorLayerLabel.visibility(isVisible)))
    }
}

/// The words the two layer lists share, so a PDF layer and a markup layer with the same name
/// are never two identical rows.
enum NavigatorLayerLabel {

    /// A markup layer's spoken name.
    ///
    /// Qualified, because a drawing's `/OCProperties` layer and a markup layer can both be
    /// called "Walls" and used to render as two identical checkboxes with VoiceOver reading
    /// "Walls, Visible" for both — with no way to tell which one hides the linework and which
    /// one hides the takeoff (CR-113). The visible text stays the bare name; the list a row
    /// sits in already says which kind it is on screen.
    static func markupLayer(_ name: String) -> String {
        String(
            format: NSLocalizedString(
                "%@, markup layer",
                comment: "Accessibility label for a markup layer row: layer name"
            ),
            name
        )
    }

    /// A document (PDF optional-content) layer's spoken name.
    static func documentLayer(_ name: String) -> String {
        String(
            format: NSLocalizedString(
                "%@, drawing layer",
                comment: "Accessibility label for a PDF optional-content layer row: layer name"
            ),
            name
        )
    }

    /// The spoken visibility state.
    static func visibility(_ isVisible: Bool) -> String {
        isVisible
            ? NSLocalizedString("Visible", comment: "Layer visibility state")
            : NSLocalizedString("Hidden", comment: "Layer visibility state")
    }

    /// Feature 30's row marker.
    static var measuringHere: String {
        NSLocalizedString(
            "Measuring here",
            comment: "Layer row marker: measuring and snapping are locked to this layer"
        )
    }

    /// The lock glyph's spoken name.
    static var locked: String {
        NSLocalizedString("Locked", comment: "Accessibility: the document locks this layer by default")
    }

    /// The lock glyph's hover help.
    static var lockedHelp: String {
        NSLocalizedString(
            "The drawing locks this layer by default.",
            comment: "Help for the lock glyph on a PDF layer row"
        )
    }

    /// The one context-menu item a drawing-layer row offers, on either list.
    static func measureLockMenuTitle(isMeasuringHere: Bool) -> String {
        isMeasuringHere
            ? NSLocalizedString(
                "Stop Measuring on One Layer",
                comment: "Layer row context menu: lift the measure lock"
            )
            : NSLocalizedString(
                "Measure Only on This Layer",
                comment: "Layer row context menu: lock measuring and snapping to this layer"
            )
    }
}

// MARK: - Layers

/// One section of the Layers page.
enum NavigatorLayersPageSection: Hashable, Identifiable {
    /// The drawing's own optional-content layers.
    case drawingLayers([NavigatorLayerRow])
    /// The markup layers on the page.
    case markupLayers([ZPDFLayerItem])

    var id: String {
        switch self {
        case .drawingLayers: return "drawing"
        case .markupLayers: return "markup"
        }
    }

    /// The section header.
    var title: String {
        switch self {
        case .drawingLayers:
            return NSLocalizedString("Drawing layers", comment: "Layers page section: the PDF's own layers")
        case .markupLayers:
            return NSLocalizedString("Markup layers", comment: "Layers page section: layers of the takeoff markups")
        }
    }
}

/// The Navigator's Layers page: the drawing's own layers and the markup layers, together.
struct NavigatorLayersList: View {

    let environment: ProjectShellEnvironment

    var body: some View {
        // ADR-0032 (r2-layers): once the project's markup layers are installed they replace the
        // name-derived list below (`Layers/MarkupLayersSection.swift`).
        let projectLayers = environment.markupLayers.isInstalled
        let sections = Self.sections(
            documentLayers: environment.navigatorLayers.rows,
            markupLayers: projectLayers ? [] : Self.markupLayers(for: environment)
        )
        if sections.isEmpty && !projectLayers {
            ZPDFEmptyState(
                glyph: .symbol(.layers),
                title: NSLocalizedString("No layers", comment: "Layers empty state title"),
                message: NSLocalizedString(
                    "Markups on this page are not assigned to a layer.",
                    comment: "Layers empty state message"
                )
            )
        } else {
            // A plain scroll of sections rather than a `List`: the list's section headers drew a
            // black material band across the navy panel, and its table rows do not render
            // off screen, so the look could not be checked without a window.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .zpdfText(.sectionHeader, .textSecondary)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, ZPDFSpacing.l)
                            .padding(.top, ZPDFSpacing.l)
                            .padding(.bottom, ZPDFSpacing.xs)
                            .accessibilityAddTraits(.isHeader)
                        Group {
                            switch section {
                            case let .drawingLayers(rows):
                                ForEach(rows) { row in
                                    NavigatorDocumentLayerRow(environment: environment, row: row, showsStateText: true)
                                        .padding(.horizontal, ZPDFSpacing.l)
                                    ZPDFHairlineDivider(leadingInset: ZPDFSpacing.l, trailingInset: ZPDFSpacing.l)
                                }
                            case let .markupLayers(layers):
                                ForEach(layers) { layer in
                                    NavigatorMarkupLayerRow(environment: environment, layer: layer, showsDetails: true)
                                        .padding(.horizontal, ZPDFSpacing.l)
                                    ZPDFHairlineDivider(leadingInset: ZPDFSpacing.l, trailingInset: ZPDFSpacing.l)
                                }
                            }
                        }
                    }
                    if projectLayers { MarkupLayersSection(environment: environment) }
                }
                .padding(.bottom, ZPDFSpacing.s)
            }
        }
    }

    /// What the Layers page shows, as a value.
    ///
    /// Both kinds, each under its own header (IM-030, BH-297). The page used to render the
    /// drawing's `/OCG` layers *instead of* the markup layers whenever the drawing had any — and
    /// most CAD exports do — so the markup-layer checkboxes its own help text promised ("Show or
    /// hide markup layers") were unreachable there, while the outline under Pages showed both.
    /// An empty kind is left out rather than shown as an empty header.
    static func sections(
        documentLayers: [NavigatorLayerRow],
        markupLayers: [ZPDFLayerItem]
    ) -> [NavigatorLayersPageSection] {
        var sections: [NavigatorLayersPageSection] = []
        if !documentLayers.isEmpty { sections.append(.drawingLayers(documentLayers)) }
        if !markupLayers.isEmpty { sections.append(.markupLayers(markupLayers)) }
        return sections
    }

    /// The markup layers for the page on screen — the one derivation both lists use.
    @MainActor
    static func markupLayers(for environment: ProjectShellEnvironment) -> [ZPDFLayerItem] {
        environment.navigatorLayers.markupLayers(
            in: environment.canvas.visibleMarkups,
            scope: NavigatorLayerScope(
                documentID: environment.document.activeTabID,
                pageID: environment.document.currentPageID
            )
        )
    }

    /// Groups markups by layer, in reading order.
    static func layers(in markups: [MarkupSummary]) -> [ZPDFLayerItem] {
        var counts: [String: Int] = [:]
        for markup in markups {
            guard let layer = markup.layer, !layer.isEmpty else { continue }
            counts[layer, default: 0] += 1
        }
        return counts
            .map { ZPDFLayerItem(name: $0.key, markupCount: $0.value) }
            .sorted(by: readingOrder)
    }

    /// Alphabetical as a person reads it (BH-818): `localizedStandardCompare`, the order used
    /// for names everywhere else in the product. `String <` compares scalars and put every
    /// capitalised name before every lower-case one — "Väggar" ahead of "dörrar".
    static func readingOrder(_ lhs: ZPDFLayerItem, _ rhs: ZPDFLayerItem) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.name < rhs.name
        }
    }
}

// MARK: - Zones

/// Project Zones: the list, and the controls that create one.
///
/// The page used to be a read-only list with a visibility checkbox, over a model nothing in the
/// product could add to. ``ProjectZonesPanel`` is the same list with the missing half attached.
struct NavigatorZonesList: View {

    let environment: ProjectShellEnvironment

    /// The Zones page's panel. An idle Escape backs out of the Navigator, as it does on every
    /// other Navigator page (R-095): the panel's own Escape handler consumes
    /// the key, so the sidebar's `onExitCommand` never heard it here.
    static func panel(environment: ProjectShellEnvironment) -> ProjectZonesPanel {
        ProjectZonesPanel(
            model: environment.projectZones,
            onExitWhenIdle: { [weak environment] in environment?.perform(.toggleNavigator) }
        )
    }

    var body: some View {
        Self.panel(environment: environment)
            .onAppear { environment.refreshProjectZones() }
            .onChange(of: environment.document.zones) { environment.refreshProjectZones() }
            .onChange(of: environment.canvas.selectedMarkupIDs) {
                environment.projectZones.setSelectedMarkupCount(
                    environment.canvas.selectedMarkupIDs.count
                )
            }
    }
}

// MARK: - Search

/// Search across text, OCR text, markups and custom fields — in this drawing, or in every
/// drawing that is open.
struct NavigatorSearchPage: View {

    /// Which drawings a query reaches. Two values, not a checkbox, because "All Drawings" and
    /// "This Drawing" are both answers a person picks — a lone ticked box leaves the unticked
    /// state unnamed.
    fileprivate enum Reach: Hashable {
        case thisDrawing
        case allDrawings
    }

    let environment: ProjectShellEnvironment
    /// Where ⌘F leaves its "put the caret in the field" request (IM-132). Optional so the page
    /// can be built on its own in a preview.
    var panelState: ShellPanelState?

    /// Where ⌘F's request reaches the field (IM-132): the design system's own focus seam, so the
    /// page uses ``ZPDFSearchField`` itself rather than a hand-made copy of its look (V-049).
    @StateObject private var fieldFocus = ZPDFSearchFieldFocus()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var search: any SearchPresenting { environment.search }

    /// The scope control appears only once there is a second drawing to search. Offering a
    /// choice between one drawing and the same one drawing is a control that does nothing.
    private var offersReachControl: Bool { environment.document.tabs.count > 1 }

    var body: some View {
        let prompt = Self.fieldPrompt(searchesAllDrawings: search.searchesAllDrawings)
        VStack(spacing: 0) {
            HStack(spacing: ZPDFSpacing.s) {
                // The design system's search field: its hover paint, clear button and Escape to
                // clear come with it, and ⌘F reaches it through its public focus seam (IM-132).
                ZPDFSearchField(
                    text: Binding(get: { search.query }, set: { search.query = $0 }),
                    placeholder: prompt,
                    accessibilityValue: search.resultSummary,
                    focus: fieldFocus,
                    onSubmit: { search.runSearch() }
                )

                optionsMenu

                ZPDFToolbarButton(
                    glyph: .symbol(.search),
                    title: NSLocalizedString("Run search", comment: "Search button")
                ) {
                    search.runSearch()
                }
                // A second press while the first search is still running would only restart it.
                .disabled(search.isSearching)
            }
            .padding(ZPDFSpacing.s)

            if !search.hits.isEmpty {
                resultStepper
                    .padding(.horizontal, ZPDFSpacing.s)
                    .padding(.bottom, ZPDFSpacing.s)
            }

            if offersReachControl {
                reachControl
                    .padding(.horizontal, ZPDFSpacing.s)
                    .padding(.bottom, ZPDFSpacing.s)
            }

            if search.showsOCRDisclaimer {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "Some results come from recognised text, which can misread a drawing.",
                        comment: "Disclaimer shown when search results include OCR text"
                    )
                )
                .padding(.horizontal, ZPDFSpacing.s)
            }

            ZPDFHairlineDivider(axis: .horizontal)

            if search.isSearching {
                // A running search is not "No results" (IM-130): a multi-drawing search used
                // to flash the empty state before its first hit landed.
                searchingRow
            }

            if search.hits.isEmpty {
                if Self.showsEmptyState(isSearching: search.isSearching, hitCount: search.hits.count) {
                    let state = Self.emptyState(
                        query: search.query,
                        scope: search.scope,
                        searchesAllDrawings: search.searchesAllDrawings,
                        offersReach: offersReachControl
                    )
                    ZPDFEmptyState(glyph: .symbol(.search), title: state.title, message: state.message)
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                List(search.hits) { hit in
                    Button {
                        // Revealing a hit can turn the page; the page-scoped panels hear of it.
                        environment.turningPage { search.selectHit(id: hit.id) }
                    } label: {
                        resultRow(hit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(hit.accessibilityLabel))
                    .accessibilityAddTraits(hit.id == search.activeHitID ? [.isSelected, .isButton] : .isButton)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { takeFocusRequest() }
        .onChange(of: panelState?.hasPendingSearchFieldFocus ?? false) { _, pending in
            if pending { takeFocusRequest() }
        }
    }

    /// ⌘F's request, honoured once.
    private func takeFocusRequest() {
        guard panelState?.takeSearchFieldFocusRequest() == true else { return }
        // On the next turn: a focus assignment made while the field is still being inserted
        // into the hierarchy is dropped by SwiftUI on macOS.
        let focus = fieldFocus
        Task { @MainActor in focus.focus() }
    }

    // MARK: Pieces

    /// Previous · "3 of 12" · Next (IM-129). `advance(by:)` always wrapped through the hits; it
    /// had no control, so stepping through forty hits meant clicking forty rows.
    private var resultStepper: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFToolbarButton(
                glyph: .symbol(.chevronUp),
                title: NSLocalizedString("Previous Result", comment: "Search: reveal the previous hit")
            ) {
                environment.advanceSearch(by: -1)
            }
            Text(Self.positionText(position: search.activeHitPosition, count: search.hits.count))
                .zpdfText(.caption, .textSecondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(Self.positionText(
                    position: search.activeHitPosition,
                    count: search.hits.count
                )))
            ZPDFToolbarButton(
                glyph: .symbol(.chevronDown),
                title: NSLocalizedString("Next Result", comment: "Search: reveal the next hit")
            ) {
                environment.advanceSearch(by: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The quiet progress state. Static under Reduce Motion: a spinner is motion.
    private var searchingRow: some View {
        HStack(spacing: ZPDFSpacing.s) {
            if reduceMotion {
                ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(Self.searchingText)
                .zpdfText(.caption, .textSecondary)
            Spacer(minLength: 0)
        }
        .padding(ZPDFSpacing.s)
        .accessibilityElement(children: .combine)
    }

    /// The scope options the presenter always had and the page never offered (IM-128): which
    /// bodies of text to look in, Match Case and Whole Words.
    private var optionsMenu: some View {
        Menu {
            SearchOptionsMenuContent(search: search)
        } label: {
            ZPDFGlyphView(.symbol(.options), size: ZPDFSpacing.Control.iconSmall)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.optionsTitle)
        .accessibilityLabel(Text(Self.optionsTitle))
        .accessibilityValue(Text(search.scope.summary))
    }

    /// This Drawing | All Drawings — the sibling idiom of the Quantities/History tab control
    /// and the Navigator switcher: labelled segments, arrow-key navigable, the selected one
    /// marked by shape as well as tint.
    private var reachControl: some View {
        ZPDFSegmentedControl(
            selection: Binding(
                get: { search.searchesAllDrawings ? Reach.allDrawings : .thisDrawing },
                set: { search.searchesAllDrawings = ($0 == .allDrawings) }
            ),
            segments: [
                ZPDFSegmentedControl.Segment(
                    value: Reach.thisDrawing,
                    title: NSLocalizedString(
                        "This Drawing",
                        comment: "Search scope: only the drawing in front"
                    ),
                    helpText: NSLocalizedString(
                        "Search only the drawing you are looking at.",
                        comment: "Tooltip for the single-drawing search scope"
                    )
                ),
                ZPDFSegmentedControl.Segment(
                    value: Reach.allDrawings,
                    title: NSLocalizedString(
                        "All Drawings",
                        comment: "Search scope: every drawing that is open"
                    ),
                    helpText: NSLocalizedString(
                        "Search every drawing that is open. Results say which drawing each one came from.",
                        comment: "Tooltip for the project-wide search scope"
                    )
                )
            ],
            accessibilityTitle: NSLocalizedString(
                "Search scope",
                comment: "Accessibility title of the This Drawing / All Drawings control"
            )
        )
        .frame(maxWidth: .infinity)
    }

    /// One result. A hit from another open drawing names that drawing on its own line, above
    /// the excerpt.
    ///
    /// Naming it is not decoration. Project-wide search puts hits from thirty drawings in one
    /// list, and a row that reads `A-101 · PDF Text` is the same row whichever drawing it came
    /// from — clicking it would look like the drawing in front had jumped to a page that does
    /// not contain the word. The label is text and a glyph, never a tint.
    @ViewBuilder
    private func resultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = hit.sourceDocumentTitle {
                HStack(spacing: ZPDFSpacing.xs) {
                    ZPDFGlyphView(.symbol(.pages), size: ZPDFSpacing.Control.iconSmall)
                    Text(title).lineLimit(1)
                }
                .zpdfText(.caption.withWeight(.semibold), .textSecondary)
            }
            Text(hit.snippet).zpdfText(.body, .textPrimary).lineLimit(2)
            Text("\(hit.pageLabel) · \(hit.source.displayName)")
                .zpdfText(.caption, .textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Words, as values

    /// The options menu's name.
    static var optionsTitle: String {
        NSLocalizedString("Search Options", comment: "Search options menu: sources, case, whole words, regex")
    }

    /// The progress line.
    static var searchingText: String {
        NSLocalizedString("Searching…", comment: "Search is running")
    }

    /// Whether the empty state ("No results", or the what-is-searched hint) is shown.
    /// Never while a search is running (IM-130): the presenter's `isSearching` existed "so the
    /// field can show a quiet progress state" and the page never read it, so a multi-drawing
    /// search flashed "No results" before its first hit arrived.
    static func showsEmptyState(isSearching: Bool, hitCount: Int) -> Bool {
        !isSearching && hitCount == 0
    }

    /// The field's placeholder and spoken name, which follow the reach: "Search this document"
    /// was shown even while All Drawings was on.
    static func fieldPrompt(searchesAllDrawings: Bool) -> String {
        searchesAllDrawings
            ? NSLocalizedString("Search all open drawings", comment: "Search field placeholder: project-wide")
            : NSLocalizedString("Search this document", comment: "Search field placeholder")
    }

    /// "3 of 12" beside the stepper; "12 results" before any hit is revealed.
    static func positionText(position: Int?, count: Int) -> String {
        guard let position else {
            return LocalizedPlural.string(
                "%lld results",
                count: count,
                one: NSLocalizedString("%lld result", comment: "Search: total hit count, singular"),
                other: NSLocalizedString("%lld results", comment: "Search: total hit count, plural")
            )
        }
        return String(
            format: NSLocalizedString(
                "%1$lld of %2$lld",
                comment: "Search: position of the revealed hit among all hits"
            ),
            Int64(position),
            Int64(count)
        )
    }

    /// The empty state's title and message, true to what the search actually does (IM-128).
    ///
    /// The old copy promised "page text, recognised text, markups and custom fields" while the
    /// default scope searched neither recognised text nor custom fields, and advised "widen the
    /// scope" when there was no scope control on screen and, with one drawing open, nothing to
    /// widen to. The message now names the sources in force and suggests only the widening that
    /// is actually available. Since L-20 the default scope searches recognised text, so the
    /// idle message names "OCR Text" among the sources it looks through.
    static func emptyState(
        query: String,
        scope: SearchScope,
        searchesAllDrawings: Bool,
        offersReach: Bool
    ) -> (title: String, message: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let names = SearchSource.allCases
                .filter { scope.sources.contains($0) }
                .map(\.displayName)
            let list = AppLanguageList.joined(names)
            return (
                fieldPrompt(searchesAllDrawings: searchesAllDrawings),
                String(
                    format: NSLocalizedString(
                        "Looks through %@. Search Options changes what is searched.",
                        comment: "Search empty state message: the list of text sources searched"
                    ),
                    list
                )
            )
        }
        let canReachFurther = offersReach && !searchesAllDrawings
        let canAddSources = scope.sources.count < SearchSource.allCases.count
        let message: String
        switch (canReachFurther, canAddSources) {
        case (true, true):
            message = NSLocalizedString(
                "Try a shorter query, search all open drawings, or include more sources in Search Options.",
                comment: "Search no-results message: both widenings are available"
            )
        case (true, false):
            message = NSLocalizedString(
                "Try a shorter query, or search all open drawings.",
                comment: "Search no-results message: only the drawing reach can widen"
            )
        case (false, true):
            message = NSLocalizedString(
                "Try a shorter query, or include more sources in Search Options.",
                comment: "Search no-results message: only the sources can widen"
            )
        case (false, false):
            message = NSLocalizedString(
                "Try a shorter or different query.",
                comment: "Search no-results message: nothing left to widen"
            )
        }
        return (NSLocalizedString("No results", comment: "Search empty state title"), message)
    }
}

#if DEBUG
struct Navigator_Previews: PreviewProvider {
    static var previews: some View {
        NavigatorSidebar(environment: .mock(), panelState: ShellPanelState())
            .frame(width: 260, height: 520)
    }
}
#endif
