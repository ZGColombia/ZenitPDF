import CoreGraphics
import Foundation
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Card rules

/// What a page card says and how it looks, as values — so the 2026-09-23 mockup's card
/// (thumbnail left; page number, then a second line; a ⋯ menu; a blue border on the page on
/// screen) is pinned by tests without rendering a view.
enum NavigatorPageCard {

    /// The card's first line: the page's position, `1`, as the mockup draws it.
    ///
    /// The position and not the label, because a label can be anything ("A-101", "iv", "3" on a
    /// set that starts numbering at three) and the first line is what the eye runs down.
    ///
    /// `position` is the card's place in the set — the list order. A page's `index` is its
    /// index in its own PDF (ADR-0022), which a reordered set no longer follows; it is the
    /// fallback only where no list position is known.
    static func title(for page: PageDescriptor, position: Int? = nil) -> String {
        ((position ?? page.index) + 1).formatted()
    }

    /// Whether the document names this page itself. An all-digit label is the reader's 1-based
    /// fallback (or a plain number), which the first line already says.
    static func hasOwnLabel(_ page: PageDescriptor) -> Bool {
        !page.label.isEmpty && !page.label.allSatisfy(\.isNumber)
    }

    /// The card's second line: the sheet's name, as the mockup puts it ("Floor Plan").
    ///
    /// ``PageDescriptor/sheetTitle`` first — the drawing's outline entry for the page, or its own
    /// label. A descriptor built without one still gets the own label here. Only when the drawing
    /// names the page nowhere does the line show the sheet size, which a person working a set
    /// does read ("ARCH D · 36 × 24 in"). Nothing is invented.
    static func subtitle(for page: PageDescriptor, usesMetric: Bool) -> String {
        if let name = sheetName(for: page) { return name }
        return sheetSizeText(page.rotatedVisibleSize, usesMetric: usesMetric)
    }

    /// How many lines the second line may take: the sheet size is one line (LT3-04 — it wrapped
    /// onto two inside the card), a sheet name up to two.
    static func subtitleLineLimit(for page: PageDescriptor) -> Int {
        sheetName(for: page) == nil ? 1 : 2
    }

    /// The sheet's name when the drawing gives one: the resolved sheet title, else the own label.
    static func sheetName(for page: PageDescriptor) -> String? {
        if let title = page.sheetTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return hasOwnLabel(page) ? page.label : nil
    }

    /// What VoiceOver calls a card: the page number
    /// and "n of m", then the sheet's name when the drawing gives one — "Page 1 of 3, Floor Plan".
    /// The sheet size is not a name and is left to the visible second line.
    /// The label with "No scale" appended when the sheet has none (NL-MEASURE-02).
    static func accessibilityLabel(for page: PageDescriptor, pageCount: Int, position: Int? = nil, isUnscaled: Bool) -> String {
        let base = accessibilityLabel(for: page, pageCount: pageCount, position: position)
        guard isUnscaled else { return base }
        return String(
            format: NSLocalizedString("%1$@, %2$@", comment: "VoiceOver label for a page card: position, then the page's own label"),
            base, NavigatorNoScaleBadge.text
        )
    }

    static func accessibilityLabel(for page: PageDescriptor, pageCount: Int, position: Int? = nil) -> String {
        let position = String(
            format: NSLocalizedString(
                "Page %1$lld of %2$lld",
                comment: "VoiceOver label for a page card: position, page count"
            ),
            Int64((position ?? page.index) + 1),
            Int64(pageCount)
        )
        guard let name = sheetName(for: page) else { return position }
        return String(
            format: NSLocalizedString(
                "%1$@, %2$@",
                comment: "VoiceOver label for a page card: position, then the page's own label"
            ),
            position,
            name
        )
    }

    /// Whether sizes are spoken in millimetres for the current user.
    static var localeUsesMetric: Bool {
        Locale.current.measurementSystem != .us
    }

    /// "ARCH D · 36 × 24 in", "A1 · 841 × 594 mm", or just the dimensions for a size with no
    /// standard name. Width first, as the sheet is seen (rotation applied).
    static func sheetSizeText(_ size: PDFSizeValue, usesMetric: Bool) -> String {
        let dimensions: String
        if usesMetric {
            let width = (size.width / 72 * 25.4).rounded()
            let height = (size.height / 72 * 25.4).rounded()
            dimensions = String(
                format: NSLocalizedString(
                    "%1$@ × %2$@ mm",
                    comment: "Navigator page card: sheet size in millimetres, width × height"
                ),
                width.formatted(.number.precision(.fractionLength(0))),
                height.formatted(.number.precision(.fractionLength(0)))
            )
        } else {
            let width = size.width / 72
            let height = size.height / 72
            dimensions = String(
                format: NSLocalizedString(
                    "%1$@ × %2$@ in",
                    comment: "Navigator page card: sheet size in inches, width × height"
                ),
                width.formatted(.number.precision(.fractionLength(0...1))),
                height.formatted(.number.precision(.fractionLength(0...1)))
            )
        }
        guard let name = standardSheetName(size) else { return dimensions }
        return String(
            format: NSLocalizedString(
                "%1$@ · %2$@",
                comment: "Navigator page card: standard sheet name · dimensions"
            ),
            name,
            dimensions
        )
    }

    /// The standard sheet sizes a construction set is drawn on, portrait, in PDF points.
    /// Names are the standards' own designations, not product terms, and are not localised.
    static let standardSheets: [(name: String, width: Double, height: Double)] = [
        ("Letter", 612, 792),
        ("Tabloid", 792, 1224),
        ("ANSI C", 1224, 1584),
        ("ANSI D", 1584, 2448),
        ("ANSI E", 2448, 3168),
        ("ARCH A", 648, 864),
        ("ARCH B", 864, 1296),
        ("ARCH C", 1296, 1728),
        ("ARCH D", 1728, 2592),
        ("ARCH E1", 2160, 3024),
        ("ARCH E", 2592, 3456),
        ("A4", 595.28, 841.89),
        ("A3", 841.89, 1190.55),
        ("A2", 1190.55, 1683.78),
        ("A1", 1683.78, 2383.94),
        ("A0", 2383.94, 3370.39)
    ]

    /// The standard name for a sheet size, in either orientation, within 3 pt (about 1 mm) —
    /// a PDF exported from CAD rounds its media box, and a size that is "almost ARCH D" is ARCH D.
    static func standardSheetName(_ size: PDFSizeValue) -> String? {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        let tolerance = 3.0
        return standardSheets.first {
            abs($0.width - short) <= tolerance && abs($0.height - long) <= tolerance
        }?.name
    }

    /// How a card is painted. Three states, told apart by border *weight* as well as colour so
    /// the difference survives greyscale and Increase Contrast; the words for VoiceOver are
    /// ``NavigatorPageThumbnail/stateText(isCurrent:isSelected:)``.
    struct Appearance: Equatable {
        /// The opaque ground under the card, if any.
        var base: ZPDFColorToken?
        /// A translucent wash over the ground, if any.
        var tint: ZPDFColorToken?
        /// Opacity of ``tint``.
        var tintOpacity: Double
        /// The border colour, if any.
        var border: ZPDFColorToken?
        /// The border width.
        var borderWidth: CGFloat
        // The hairline under a card is `NavigatorPagesList.showsSeparator(after:highlighted:)`'s
        // rule, which also looks at the neighbour and the last card (R-092: a second, simpler
        // copy lived here and only tests read it).
    }

    /// The paint for a card: the page on screen is raised and framed in the mockup's 2 pt
    /// accent; a page only in the Navigator's selection gets an accent wash and a 1 pt frame;
    /// hover is the design system's hover overlay; everything else lies flat on the panel.
    static func appearance(isCurrent: Bool, isSelected: Bool, isHovered: Bool) -> Appearance {
        if isCurrent {
            return Appearance(
                base: NavigatorStyle.raisedFill,
                tint: nil,
                tintOpacity: 0,
                border: NavigatorStyle.stateLine,
                borderWidth: NavigatorStyle.currentBorder
            )
        }
        if isSelected {
            return Appearance(
                base: nil,
                tint: NavigatorStyle.accent,
                tintOpacity: NavigatorStyle.selectionTint,
                border: NavigatorStyle.stateLine,
                borderWidth: NavigatorStyle.selectedBorder
            )
        }
        return Appearance(
            base: nil,
            tint: isHovered ? NavigatorStyle.hover : nil,
            // The hover token is translucent by definition; it is composited as it stands.
            tintOpacity: isHovered ? 1 : 0,
            border: nil,
            borderWidth: 0
        )
    }
}

// MARK: - Page actions (the card's ⋯ menu)

/// What a page card's ⋯ menu (and its context menu) offers. Every item runs a command the
/// product already has, on this page — no item is decoration.
enum NavigatorPageAction: String, CaseIterable, Identifiable {
    /// Show this page on the canvas.
    case show
    /// Add the page to the Navigator's selection, or take it out (the Command-click, by menu).
    case toggleSelection
    /// Show the page and fit it in the window.
    case fitPage
    /// Show the page and fit its width.
    case fitWidth
    /// Show the page and start Calibrate Scale on it.
    case calibrate
    /// Show the page and open its Scale Regions.
    case scaleRegions

    var id: String { rawValue }

    /// The menu item's title. The selection item names what it will do to *this* page.
    static func title(for action: NavigatorPageAction, isSelected: Bool) -> String {
        switch action {
        case .show:
            return NSLocalizedString("Show Page", comment: "Navigator page menu: show this page on the canvas")
        case .toggleSelection:
            return isSelected
                ? NSLocalizedString("Remove from Selection", comment: "Navigator page menu: take the page out of the selection")
                : NSLocalizedString("Add to Selection", comment: "Navigator page menu: add the page to the selection")
        case .fitPage:
            return NSLocalizedString("Fit Page in Window", comment: "Navigator page menu: show and fit the page")
        case .fitWidth:
            return NSLocalizedString("Fit Width", comment: "Navigator page menu: show the page and fit its width")
        case .calibrate:
            return NSLocalizedString("Calibrate Scale…", comment: "Navigator page menu: calibrate this page")
        case .scaleRegions:
            return NSLocalizedString("Scale Regions…", comment: "Navigator page menu: open this page's scale regions")
        }
    }

    /// The glyph beside the item.
    var glyph: ZPDFGlyph {
        switch self {
        case .show: return .symbol(.pages)
        case .toggleSelection: return .symbol(.select)
        case .fitPage: return .symbol(.fitPage)
        case .fitWidth: return .symbol(.fitWidth)
        case .calibrate: return .symbol(.measure)
        case .scaleRegions: return .symbol(.scaleRegions)
        }
    }

    /// Where the menu puts a divider before this item.
    var startsGroup: Bool {
        self == .fitPage || self == .calibrate
    }

    /// Runs the action on `pageID`, through the environment's page turn so the page-scoped
    /// panels hear of it (BH-296), then the command the item names.
    @MainActor
    func perform(pageID: PageDescriptor.ID, in environment: ProjectShellEnvironment) {
        switch self {
        case .show:
            environment.selectPage(id: pageID, mode: .replace)
        case .toggleSelection:
            environment.selectPage(id: pageID, mode: .toggle)
        case .fitPage:
            environment.selectPage(id: pageID, mode: .replace)
            environment.perform(.fitPage)
        case .fitWidth:
            environment.selectPage(id: pageID, mode: .replace)
            environment.perform(.fitWidth)
        case .calibrate:
            environment.selectPage(id: pageID, mode: .replace)
            environment.perform(.calibrateScale)
        case .scaleRegions:
            environment.selectPage(id: pageID, mode: .replace)
            // The command toggles the panel. "Open this page's Scale Regions" must never be
            // the click that closes them, so an open panel is only refreshed for the new page.
            if environment.isPanelOpen(.scaleRegions) {
                environment.refreshScaleRegions()
            } else {
                environment.perform(.scaleRegions)
            }
        }
    }

    /// The ⋯ button's accessibility name: "Page 3 options", so a column
    /// of menu buttons is told apart by ear.
    ///
    /// `position` is the card's place in the set, the number the card itself shows (ADR-0022).
    /// Without it the label fell back to the page's index in its own PDF, so a reordered or
    /// combined set announced the wrong number, or two cards the same one (R-093).
    static func menuLabel(for page: PageDescriptor, position: Int? = nil) -> String {
        String(
            format: NSLocalizedString(
                "Page %@ options",
                comment: "Accessibility label for a page card's ⋯ menu button: page number"
            ),
            NavigatorPageCard.title(for: page, position: position)
        )
    }

    /// The ⋯ button's hover help and VoiceOver hint, naming the page it acts on: "Actions for
    /// page 3, A-101" — a column of identical "Page Options" buttons says nothing about which is
    /// which.
    ///
    /// S-057: the page is named the way ``menuLabel(for:position:)`` names it — its place in the
    /// set — followed by the sheet's own number or label when it has one. It used to name the PDF
    /// label through the P-badge text ("P7"), a badge the card no longer draws, so a reordered set
    /// read "Page 3 options, Actions for page P7" for one button.
    static func menuHint(for page: PageDescriptor, position: Int? = nil) -> String {
        let number = NavigatorPageCard.title(for: page, position: position)
        let own = page.sheetNumber.flatMap { $0.isEmpty ? nil : $0 }
            ?? (NavigatorPageCard.hasOwnLabel(page) ? page.label : nil)
        guard let own else {
            return String(
                format: NSLocalizedString(
                    "Actions for page %@",
                    comment: "Help and VoiceOver hint for a page card's ⋯ menu: the page's place in the set"
                ),
                number
            )
        }
        return String(
            format: NSLocalizedString(
                "Actions for page %1$@, %2$@",
                comment: "Help and VoiceOver hint for a page card's ⋯ menu: the page's place in the set, its sheet number or label"
            ),
            number, own
        )
    }
}

// MARK: - Set actions (the active drawing's ⋯ menu)

/// The drawing-set items the active drawing's ⋯ menu offers ahead of the File commands: the
/// NL-DOCS set outputs and Combine (NL-DOCS-04/08/10/13).
///
/// R-071: they lived only in ``NavigatorFileHeader``'s menu, which renders only for pages
/// without a tab summary — and the application always installs one — so all five were built,
/// tested and out of reach. One list, drawn by ``NavigatorSetActionsMenu`` in both headers.
enum NavigatorSetAction: String, CaseIterable, Identifiable, Sendable {
    case exportArrangedSet
    case linkSheetReferences
    case setCompareReport
    case splitIntoSheets
    case combineOpenDrawings

    var id: String { rawValue }

    /// The items wired and meaningful now, in menu order: the set outputs (the compare report
    /// only with a previous revision), then Combine while another drawing is open.
    @MainActor
    static func offered(in environment: ProjectShellEnvironment) -> [NavigatorSetAction] {
        allCases.filter { action in
            switch action {
            case .exportArrangedSet: return environment.onExportArrangedSet != nil
            case .linkSheetReferences: return environment.onLinkSheetReferences != nil
            case .setCompareReport: return environment.hasPreviousRevision && environment.onSetCompareReport != nil
            case .splitIntoSheets: return environment.onSplitIntoSheets != nil
            case .combineOpenDrawings:
                return environment.onCombineOpenDrawings != nil
                    && !NavigatorFileHeader.otherDrawings(in: environment.document).isEmpty
            }
        }
    }

    var title: String {
        switch self {
        case .exportArrangedSet: return NavigatorFileAction.exportArrangedSetTitle
        case .linkSheetReferences: return NavigatorFileAction.linkSheetReferencesTitle
        case .setCompareReport: return NavigatorFileAction.setCompareReportTitle
        case .splitIntoSheets: return NavigatorFileAction.splitIntoSheetsTitle
        case .combineOpenDrawings: return NavigatorFileAction.combineTitle
        }
    }

    var glyph: ZPDFGlyph {
        switch self {
        case .exportArrangedSet: return .symbol(.export)
        case .linkSheetReferences: return .symbol(.bookmarks)
        case .setCompareReport: return .symbol(.revisionCompare)
        case .splitIntoSheets, .combineOpenDrawings: return .symbol(.pages)
        }
    }

    /// Combine is its own group: it changes the project, the others write files.
    var startsGroup: Bool { self == .combineOpenDrawings }

    @MainActor
    func perform(in environment: ProjectShellEnvironment) {
        switch self {
        case .exportArrangedSet: environment.onExportArrangedSet?()
        case .linkSheetReferences: environment.onLinkSheetReferences?()
        case .setCompareReport: environment.onSetCompareReport?()
        case .splitIntoSheets: environment.onSplitIntoSheets?()
        case .combineOpenDrawings: environment.onCombineOpenDrawings?()
        }
    }
}

/// The set items of a ⋯ menu, with a divider after them; nothing when none is offered.
struct NavigatorSetActionsMenu: View {
    let environment: ProjectShellEnvironment
    let actions: [NavigatorSetAction]

    var body: some View {
        if !actions.isEmpty {
            ForEach(Array(actions.enumerated()), id: \.element) { position, action in
                if action.startsGroup && position > 0 { Divider() }
                Button {
                    action.perform(in: environment)
                } label: {
                    Label { Text(action.title) } icon: {
                        ZPDFGlyphView(action.glyph, size: ZPDFSpacing.Control.icon)
                    }
                }
            }
            Divider()
        }
    }
}

// MARK: - File actions (the file header's ⋯ menu)

/// What the file header's ⋯ menu offers: the File commands, on the drawing the header names.
enum NavigatorFileAction: String, CaseIterable, Identifiable {
    /// Show the Open Drawings list in the Navigator. Offered only while more than one is open.
    /// It heads the menu with the other drawings, since it replaced the
    /// Drawings segment.
    case showOpenDrawings
    case save
    case saveAs
    case export
    case print
    case close

    var id: String { rawValue }

    /// The Combine item's title (NL-DOCS-04); offered beside the actions with other drawings open.
    static var combineTitle: String {
        NSLocalizedString(
            "Combine Open Drawings into This Project…",
            comment: "Navigator file menu: add every other open drawing, with its takeoff, to this project"
        )
    }

    static var exportArrangedSetTitle: String {
        NSLocalizedString("Export Arranged Set…", comment: "Navigator file menu: write the set, as arranged, to a new PDF")
    }
    static var linkSheetReferencesTitle: String {
        NSLocalizedString("Link Sheet References…", comment: "Navigator file menu: link every sheet reference in the set to its sheet")
    }
    static var setCompareReportTitle: String {
        NSLocalizedString("Set Compare Report…", comment: "Navigator file menu: compare every sheet with the newest revision and write a report")
    }
    static var splitIntoSheetsTitle: String {
        NSLocalizedString("Split into Sheets…", comment: "Navigator file menu: write one PDF per sheet, named by sheet number")
    }

    /// The actions offered with `openDrawings` drawings open.
    static func offered(openDrawings: Int) -> [NavigatorFileAction] {
        allCases.filter { $0 != .showOpenDrawings || openDrawings > 1 }
    }

    /// The command the item runs, or `nil` for the one that only changes the Navigator page.
    var command: ZPDFCommandID? {
        switch self {
        case .save: return .save
        case .saveAs: return .saveAs
        case .export: return .export
        case .print: return .print
        case .showOpenDrawings: return nil
        case .close: return .closeTab
        }
    }

    var title: String {
        switch self {
        case .save: return NSLocalizedString("Save", comment: "Navigator file menu")
        case .saveAs: return NSLocalizedString("Save As…", comment: "Navigator file menu")
        case .export: return NSLocalizedString("Export…", comment: "Navigator file menu")
        case .print: return NSLocalizedString("Print…", comment: "Navigator file menu")
        case .showOpenDrawings: return NSLocalizedString("Show Open Drawings", comment: "Navigator file menu: switch to the open-drawings list")
        case .close: return NSLocalizedString("Close Drawing", comment: "Navigator file menu: close this drawing's tab")
        }
    }

    var glyph: ZPDFGlyph {
        switch self {
        case .save: return .symbol(.save)
        case .saveAs: return .symbol(.duplicate)
        case .export: return .symbol(.export)
        case .print: return .symbol(.print)
        case .showOpenDrawings: return .symbol(.open)
        case .close: return .symbol(.close)
        }
    }

    /// Where the menu puts a divider before this item (never before the first item shown).
    var startsGroup: Bool {
        self == .save || self == .export || self == .close
    }

    @MainActor
    func perform(in environment: ProjectShellEnvironment, panelState: ShellPanelState?) {
        if let command {
            environment.perform(command)
        } else {
            panelState?.navigatorSection = .drawings
        }
    }

    /// The ⋯ button's accessibility name.
    static var menuLabel: String {
        NSLocalizedString("Document Options", comment: "Accessibility label for the Navigator file header's ⋯ menu button")
    }

    /// The ⋯ button's hover help and VoiceOver hint: "Actions for A1.01 - Floor Plan.pdf".
    static func menuHint(for title: String) -> String {
        String(
            format: NSLocalizedString(
                "Actions for %@",
                comment: "Accessibility label for the Navigator file header's action menu: drawing name"
            ),
            title
        )
    }
}

// MARK: - Views

/// The mockup's ⋯ button: a borderless menu with a round hover wash and a focus ring.
struct NavigatorMoreMenu<Items: View>: View {

    let accessibilityLabel: String
    /// Hover help and VoiceOver hint: what the menu acts on.
    var hint: String? = nil
    @ViewBuilder let items: () -> Items

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            items()
        } label: {
            ZPDFGlyphView(.symbol(.more), size: ZPDFSpacing.Control.icon)
                .foregroundStyle(isHovered ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
                .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
                .background {
                    Circle()
                        .fill(ZPDFColor.color(NavigatorStyle.hover))
                        .opacity(isHovered ? 1 : 0)
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(ZPDFMotion.animation(.micro, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .help(hint ?? accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(hint ?? ""))
    }
}

/// The page card's menu items, shared by the ⋯ button and the context menu so the two never
/// drift apart.
struct NavigatorPageActionItems: View {

    let environment: ProjectShellEnvironment
    let pageID: PageDescriptor.ID
    let isSelected: Bool
    /// Opens the card's inline sheet-name editor (NL-DOCS-05); `nil` hides the item.
    var onNameSheet: (() -> Void)? = nil

    var body: some View {
        ForEach(NavigatorPageAction.allCases) { action in
            if action.startsGroup { Divider() }
            Button {
                action.perform(pageID: pageID, in: environment)
            } label: {
                Label {
                    Text(NavigatorPageAction.title(for: action, isSelected: isSelected))
                } icon: {
                    ZPDFGlyphView(action.glyph, size: ZPDFSpacing.Control.icon)
                }
            }
        }
        if let onNameSheet, environment.onNameSheet != nil {
            Divider()
            Button {
                onNameSheet()
            } label: {
                Label {
                    Text(NavigatorSheetNameEditor.menuTitle)
                } icon: {
                    ZPDFGlyphView(.symbol(.text), size: ZPDFSpacing.Control.icon)
                }
            }
        }
        NavigatorArrangeItems(environment: environment, pageID: pageID)
        NavigatorViewItems(environment: environment, pageID: pageID)
    }
}

/// The file header over the page cards: the drawing's name and its ⋯ menu of File commands.
struct NavigatorFileHeader: View {

    let environment: ProjectShellEnvironment
    let panelState: ShellPanelState?

    /// The active drawing's title, or `nil` with no drawing open (the header is then hidden).
    static func title(for document: any DocumentPresenting) -> String? {
        document.tabs.first { $0.id == document.activeTabID }?.title
    }

    /// The other open drawings, in tab order — the menu's "switch to" items.
    static func otherDrawings(in document: any DocumentPresenting) -> [DocumentTabSummary] {
        document.tabs.filter { $0.id != document.activeTabID }
    }

    /// The name's hover help: the whole title, plus the file name when the title is not it, so a
    /// middle-truncated name is always recoverable.
    static func tooltip(title: String, fileName: String?) -> String {
        guard let fileName, !fileName.isEmpty, fileName != title else { return title }
        return String(
            format: NSLocalizedString(
                "%1$@ — %2$@",
                comment: "Navigator file header tooltip: drawing title — file name"
            ),
            title,
            fileName
        )
    }

    var body: some View {
        if let title = Self.title(for: environment.document) {
            let tab = environment.document.tabs.first { $0.id == environment.document.activeTabID }
            let others = Self.otherDrawings(in: environment.document)
            let actions = NavigatorFileAction.offered(openDrawings: environment.document.tabs.count)
            HStack(spacing: ZPDFSpacing.xs) {
                if tab?.hasUnsavedChanges == true {
                    // The same unsaved dot the tab carries; spoken through the tab's label.
                    Circle()
                        .fill(ZPDFColor.color(NavigatorStyle.indicator))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                // ~13 pt semibold, middle-truncated so the sheet number at the start and
                // the extension at the end both survive; the whole name is in the tooltip. It
                // takes every point the row has left (layout priority over the menu's gap).
                Text(title)
                    .zpdfText(.rowLabel.withWeight(.semibold), .textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .help(Self.tooltip(title: title, fileName: tab?.fileName))
                    .accessibilityLabel(Text(tab?.accessibilityLabel ?? title))
                    .accessibilityAddTraits(.isHeader)
                NavigatorMoreMenu(
                    accessibilityLabel: NavigatorFileAction.menuLabel,
                    hint: NavigatorFileAction.menuHint(for: title)
                ) {
                    NavigatorSetActionsMenu(environment: environment, actions: NavigatorSetAction.offered(in: environment))
                    if !others.isEmpty {
                        // Switch to another open drawing: the tab strip's own hook, so the window
                        // switches, not just the summary.
                        Section(NSLocalizedString("Switch To", comment: "Navigator file menu: section of the other open drawings")) {
                            ForEach(others) { other in
                                Button(other.title) { environment.tabBar.onSelect?(other.id) }
                                    .help(other.fileName)
                            }
                        }
                    }
                    ForEach(Array(actions.enumerated()), id: \.element) { position, action in
                        if action.startsGroup && position > 0 { Divider() }
                        Button {
                            action.perform(in: environment, panelState: panelState)
                        } label: {
                            Label {
                                Text(action.title)
                            } icon: {
                                ZPDFGlyphView(action.glyph, size: ZPDFSpacing.Control.icon)
                            }
                        }
                    }
                }
            }
            .padding(.leading, ZPDFSpacing.l)
            .padding(.trailing, ZPDFSpacing.xs)
            .frame(height: NavigatorStyle.fileHeaderHeight)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The head of the Open Drawings list, which is reached from the file header's ⋯ menu rather
/// than a segment: its name, and the way back to Pages (Escape still closes the Navigator).
struct NavigatorDrawingsHeader: View {

    @Bindable var panelState: ShellPanelState

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(NavigatorSection.drawings.displayName)
                .zpdfText(.rowLabel.withWeight(.semibold), .textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(Self.backTitle) { panelState.navigatorSection = .pages }
                .buttonStyle(.borderless)
                .zpdfFont(.control)
                .foregroundStyle(ZPDFColor.color(NavigatorStyle.indicator))
                .help(NSLocalizedString("Back to the pages of this drawing", comment: "Open Drawings header: help for the Back button"))
        }
        .padding(.leading, ZPDFSpacing.l)
        .padding(.trailing, ZPDFSpacing.m)
        .frame(height: NavigatorStyle.fileHeaderHeight)
    }

    /// The way back.
    static var backTitle: String {
        NSLocalizedString("Back to Pages", comment: "Open Drawings header: return to the Pages list")
    }
}


/// The card's "No scale" badge (NL-MEASURE-02): words and a glyph, never colour alone.
struct NavigatorNoScaleBadge: View {
    static var text: String {
        NSLocalizedString("No scale", comment: "Navigator card badge: this sheet has no scale of its own")
    }

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(.symbol(.measure), size: ZPDFSpacing.Control.iconSmall)
            Text(Self.text).zpdfText(.caption, .textSecondary)
        }
        .foregroundStyle(ZPDFColor.textSecondary)
        .padding(.horizontal, ZPDFSpacing.xs)
        .overlay(Capsule().strokeBorder(ZPDFColor.color(NavigatorStyle.hairline), lineWidth: ZPDFStroke.regular))
        .accessibilityHidden(true)   // spoken as part of the card's label
    }
}
