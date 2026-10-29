import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The strip of open documents, under the brand in the window's top band.
///
/// Drawn after the 2026-09-23 main-window mockup. The front
/// document is a raised tab whose top corners are rounded and whose foot flares into the baseline
/// hairline; back tabs have no fill of their own and take a wash only under the pointer. The `+`
/// is always the last thing in the strip and is **always visible**: when the strip is too narrow
/// for every tab at its natural width the tabs shrink — in the band's left column only down to
/// the width that keeps about ten characters of the name readable, after which the top band gives
/// the strip a full-width row of its own (L-24); in that row down to 72 pt, the name
/// middle-truncated and whole in the tooltip (LT3-03) — and only past that do the tabs that do
/// not fit move into a trailing › menu. The strip never clips a tab and never scrolls.
///
/// A tab's file name has priority over everything else in it. The tab shows it without its
/// extension (L-24); the full name is the tooltip's first line and the spoken label's first
/// word. The unsaved state is a dot before the name (shape, not tint, and spoken as "edited");
/// the revision badge shows only when the name still fits beside it; both are always in the
/// tab's tooltip.
public struct DocumentTabBarView: View {

    private let model: DocumentTabBarModel

    /// Creates the tab bar over its tabs and their actions.
    ///
    /// The strip shows only documents: Export sits in the toolbar's right group and the
    /// Inspector carries its own close button and edge ear. (S-055: the strip's own trailing
    /// Export and Inspector controls, never shown in the product, were deleted — their Export ran
    /// the ledger-only export rather than the toolbar's chooser.)
    public init(model: DocumentTabBarModel) {
        self.model = model
    }

    public var body: some View {
        // Read once per render (IM-224): `items` is derived from the presenter on every read.
        let items = model.items
        HStack(alignment: .bottom, spacing: 0) {
            GeometryReader { proxy in
                let plan = DocumentTabStripPlan.make(
                    tabCount: items.count,
                    activeIndex: items.firstIndex(where: \.isActive),
                    available: proxy.size.width
                )
                HStack(alignment: .bottom, spacing: DocumentTabMetrics.spacing) {
                    if items.isEmpty {
                        emptyBar
                    }
                    ForEach(plan.visible, id: \.self) { index in
                        DocumentTabView(item: items[index], model: model, width: plan.tabWidth)
                            .modifier(DocumentTabDragModifier(item: items[index], model: model))
                    }
                    if !plan.overflow.isEmpty {
                        DocumentTabOverflowMenu(items: plan.overflow.map { items[$0] }, model: model)
                    }
                    DocumentNewTabButton(action: model.newTab)
                }
                .padding(.leading, DocumentTabMetrics.leadingInset)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // The baseline the tabs stand on. Drawn under the tabs, so the front tab's fill covers
        // it and the tab reads as one surface with the content below.
        .background(alignment: .bottom) { ZPDFHairlineDivider(axis: .horizontal) }
        // The strip is the lower half of the window's top band, on the same chrome ground as
        // the toolbar above it; its baseline is the band's single lower edge.
        .background(ZPDFColor.color(DocumentTabPalette.ground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Open documents",
            comment: "Accessibility label for the document tab bar"
        )))
    }

    private var emptyBar: some View {
        Text(NSLocalizedString("No document open", comment: "Tab bar state with no documents"))
            .zpdfText(.control, .textTertiary)
            .lineLimit(1)
            .padding(.horizontal, ZPDFSpacing.s)
            .frame(height: DocumentTabMetrics.height)
    }
}

// MARK: - Fitting the strip

/// How the strip lays its tabs out in a given width: every tab at one width, and which tabs are
/// in the strip and which in the › menu. Pure, so the no-clip rule is testable without drawing.
struct DocumentTabStripPlan: Equatable {

    /// The width every visible tab is drawn at.
    let tabWidth: CGFloat
    /// Indices of the tabs drawn in the strip, in order.
    let visible: [Int]
    /// Indices of the tabs in the › menu, in order.
    let overflow: [Int]

    /// The narrowest strip that shows `tabCount` tabs at `tabWidth` (by default
    /// ``DocumentTabMetrics/minimumWidth``) with no › menu, the `+` included. The top band
    /// compares its tab column with this at ``DocumentTabMetrics/readableWidth`` to decide
    /// whether the tabs need their own full-width row.
    static func minimumStripWidth(tabCount: Int, tabWidth: CGFloat = DocumentTabMetrics.minimumWidth) -> CGFloat {
        let count = CGFloat(max(1, tabCount))
        return DocumentTabMetrics.leadingInset
            + count * tabWidth
            + (count - 1) * DocumentTabMetrics.spacing
            + DocumentTabMetrics.spacing + DocumentTabMetrics.newTabWidth
    }

    /// The plan for `tabCount` tabs in `available` points, the `+` always included.
    ///
    /// 1. Every tab at its natural width, when they fit.
    /// 2. Otherwise every tab shrunk to share the width, down to the minimum.
    /// 3. Otherwise as many minimum-width tabs as fit beside the › menu — the front tab always
    ///    among them — and the rest in the menu.
    static func make(tabCount: Int, activeIndex: Int?, available: CGFloat) -> DocumentTabStripPlan {
        guard tabCount > 0 else {
            return DocumentTabStripPlan(tabWidth: DocumentTabMetrics.naturalWidth, visible: [], overflow: [])
        }
        let spacing = DocumentTabMetrics.spacing
        // Room left for tabs once the inset and the `+` (with its gap) are paid for.
        let room = max(0, available - DocumentTabMetrics.leadingInset - DocumentTabMetrics.newTabWidth - spacing)
        let count = CGFloat(tabCount)
        let natural = DocumentTabMetrics.naturalWidth
        let minimum = DocumentTabMetrics.minimumWidth

        if count * natural + (count - 1) * spacing <= room {
            return DocumentTabStripPlan(tabWidth: natural, visible: Array(0..<tabCount), overflow: [])
        }
        let shared = floor((room - (count - 1) * spacing) / count)
        if shared >= minimum {
            return DocumentTabStripPlan(tabWidth: shared, visible: Array(0..<tabCount), overflow: [])
        }

        // Overflow: the › menu takes its place first. At least one tab stays in the strip, and
        // it may drop under the minimum rather than disappear — a strip with only `›` and `+`
        // would hide which document is in front.
        let menuRoom = max(0, room - DocumentTabMetrics.overflowWidth - spacing)
        let fitting = max(1, min(tabCount - 1, Int(floor((menuRoom + spacing) / (minimum + spacing)))))
        let width = max(
            DocumentTabMetrics.floorWidth,
            min(natural, floor((menuRoom - CGFloat(fitting - 1) * spacing) / CGFloat(fitting)))
        )
        var visible = Array(0..<fitting)
        if let activeIndex, activeIndex >= fitting, activeIndex < tabCount {
            visible[fitting - 1] = activeIndex
        }
        let overflow = (0..<tabCount).filter { !visible.contains($0) }
        return DocumentTabStripPlan(tabWidth: width, visible: visible, overflow: overflow)
    }
}

// MARK: - Look

/// The tab strip's measurements, from the mockup.
enum DocumentTabMetrics {
    /// A tab's height, foot included.
    static let height: CGFloat = ZPDFSpacing.Chrome.documentTabHeight
    /// The rounding of a tab's two top corners.
    static let topRadius: CGFloat = ZPDFRadius.card
    /// How far a tab's foot flares out into the baseline on each side.
    static let flare: CGFloat = 5
    /// The gap between neighbouring tabs.
    static let spacing: CGFloat = 2
    /// The strip's inset from the band's left edge.
    static let leadingInset: CGFloat = 8
    /// A tab's width when there is room: the mockup's 226 pt.
    static let naturalWidth: CGFloat = 226
    /// The narrowest a tab shrinks to before tabs move into the › menu.
    ///
    /// LT3-03 (2026-09-23): all open drawings must be visible. This was 150 pt, so two
    /// documents in the top band's ~300 pt column already sent the second into the › menu. A
    /// 72 pt tab keeps the start and end of the name (middle truncation) with the full name in
    /// the tooltip, and the band gives the strip a full-width row when even that does not fit
    /// (``ProjectTopBandView``), so the menu is reached only past about twelve documents.
    static let minimumWidth: CGFloat = 72
    /// The narrowest the one remaining tab may be squeezed to in a very narrow strip.
    static let floorWidth: CGFloat = 56

    // The parts of a tab around its title. The tab's body is built from these, so the room the
    // title gets (``titleRoom(tabWidth:hasUnsavedDot:)``) is the room it is actually drawn in.

    /// From the tab's left edge to its title (or unsaved dot): the spec's leading inset plus
    /// the foot's flare.
    static let titleLeadingInset: CGFloat = ZPDFSpacing.l + flare
    /// From the close button to the tab's right edge.
    static let trailingInset: CGFloat = ZPDFSpacing.xs + flare
    /// The gap between the title button and the close button.
    static let closeGap: CGFloat = ZPDFSpacing.xs
    /// The close button's frame, reserved whether or not it shows (IM-136).
    static let closeWidth: CGFloat = ZPDFSpacing.Control.minimumHitTarget
    /// The gap between the unsaved dot and the title.
    static let dotGap: CGFloat = ZPDFSpacing.s

    /// Everything in a tab that is not its title.
    static func chromeWidth(hasUnsavedDot: Bool) -> CGFloat {
        titleLeadingInset + (hasUnsavedDot ? unsavedDot + dotGap : 0) + closeGap + closeWidth + trailingInset
    }

    /// The width a tab of `tabWidth` leaves for its title.
    static func titleRoom(tabWidth: CGFloat, hasUnsavedDot: Bool) -> CGFloat {
        max(0, tabWidth - chromeWidth(hasUnsavedDot: hasUnsavedDot))
    }

    /// The title room a readable tab keeps: about ten characters of the 14 pt tab title (L-24).
    /// Measured: ten-character drawing names take 68–73 pt regular or medium ("Takplan 12",
    /// "Plan-A-rev", "A-101 Roof"), a digit-heavy one up to 83 pt ("Scan-C-002").
    static let readableTitleWidth: CGFloat = 76
    /// The narrowest tab whose name is still readable — about ten characters beside the close
    /// button; an unsaved tab gives two of them to its dot (L-24).
    ///
    /// Live test 5 (2026-10-03): the band kept three tabs in its ~330 pt left column at 87 pt
    /// each, which left 33 pt for a title ("Pl...df") while most of a 1 728 pt band stood empty.
    /// The band now gives the tabs the free width up to the tools, and the tabs their own
    /// full-width row when even that cannot hold them at this width
    /// (``ProjectTopBandView/tabsNeedOwnRow(tabCount:leftColumn:)``). Only in that full-width
    /// row may tabs shrink further, towards ``minimumWidth``: every open drawing keeps a visible
    /// tab (LT3-03) before any moves into the › menu.
    static var readableWidth: CGFloat {
        chromeWidth(hasUnsavedDot: false) + readableTitleWidth
    }
    /// The `+` tab's width.
    static let newTabWidth: CGFloat = 44
    /// The › overflow menu's width.
    static let overflowWidth: CGFloat = 28
    /// The unsaved dot's diameter.
    static let unsavedDot: CGFloat = 6
}

/// Every colour the tab strip draws, as design-system tokens: one place to read, and a test pins
/// that none of it is a raw colour.
enum DocumentTabPalette {
    /// The strip's ground: the window chrome the toolbar stands on.
    static let ground: ZPDFColorToken = ZPDFWindowChrome.groundToken
    /// The front tab's fill: the raised chrome the mockup draws the open document in.
    static let activeFill: ZPDFColorToken = .elevated
    /// The front tab's outline along its top and sides — the stronger hairline, which is what
    /// lifts it off the strip.
    static let activeStroke: ZPDFColorToken = .borderStrong
    /// The `+` tab's fill (`tabInactive`). Back document tabs have no fill at all.
    static let newTabFill: ZPDFColorToken = .surface
    /// The wash a back tab, the `+`, the › and the close button take under the pointer.
    static let hover: ZPDFColorToken = .stateHover
    /// The front tab's title and glyphs.
    static let activeTitle: ZPDFColorToken = .textPrimary
    /// A back tab's title and the revision badge.
    static let inactiveTitle: ZPDFColorToken = .textSecondary
    /// The revision badge's recessed ground and its outline.
    static let badgeFill: ZPDFColorToken = .inset
    static let badgeStroke: ZPDFColorToken = .border
    /// The unsaved dot before the title.
    static let unsavedDot: ZPDFColorToken = .accentBlue

    /// Every token above, for the token-use test.
    static let all: [ZPDFColorToken] = [
        ground, activeFill, activeStroke, newTabFill, hover, activeTitle, inactiveTitle,
        badgeFill, badgeStroke, unsavedDot
    ]

    /// The fill a document tab draws for its state: the front tab only.
    static func fill(isActive: Bool) -> ZPDFColorToken? {
        isActive ? activeFill : nil
    }

    /// The wash drawn over a tab: only a back tab under the pointer takes one. The front tab is
    /// already raised; washing it too would make hover look like selection.
    static func overlay(isActive: Bool, isHovering: Bool) -> ZPDFColorToken? {
        guard !isActive else { return nil }
        return ZPDFInteractionState.resolve(isHovering: isHovering, isPressed: false).overlay
    }
}

/// A document tab's ground for its state: the front tab's fill and outline, or, for a back tab,
/// nothing but the hover wash.
struct DocumentTabGround: View {
    let isActive: Bool
    let isHovering: Bool

    var body: some View {
        ZStack {
            if let fill = DocumentTabPalette.fill(isActive: isActive) {
                DocumentTabShape().fill(ZPDFColor.color(fill))
                DocumentTabShape(closed: false)
                    .stroke(ZPDFColor.color(DocumentTabPalette.activeStroke), lineWidth: ZPDFStroke.regular)
            }
            if let overlay = DocumentTabPalette.overlay(isActive: isActive, isHovering: isHovering) {
                DocumentTabShape().fill(ZPDFColor.color(overlay))
            }
        }
    }
}

/// A document tab's outline: rounded top corners, straight sides, and a foot that flares out
/// into the baseline on both sides. `closed` adds the bottom edge for filling; the open form is
/// the stroke, which must not draw a line across the tab's foot.
struct DocumentTabShape: Shape {

    var topRadius: CGFloat = DocumentTabMetrics.topRadius
    var flare: CGFloat = DocumentTabMetrics.flare
    var closed: Bool = true

    func path(in rect: CGRect) -> Path {
        let radius = min(topRadius, rect.height / 2, (rect.width - 2 * flare) / 2)
        let foot = min(flare, rect.height / 2)
        let left = rect.minX + foot
        let right = rect.maxX - foot
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        // The left foot curls out of the baseline and up into the side.
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY - foot),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: rect.minY),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: right - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.minY + radius),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY - foot))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: right, y: rect.maxY)
        )
        if closed { path.closeSubpath() }
        return path
    }
}

/// The tab-shaped `+`, always the strip's last item.
struct DocumentNewTabButton: View {

    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZPDFGlyphView(.symbol(.add), size: ZPDFSpacing.Control.icon)
                .foregroundStyle(ZPDFColor.color(
                    isHovering ? DocumentTabPalette.activeTitle : DocumentTabPalette.inactiveTitle
                ))
                .frame(width: DocumentTabMetrics.newTabWidth, height: DocumentTabMetrics.height)
                .background {
                    DocumentTabShape().fill(ZPDFColor.color(DocumentTabPalette.newTabFill))
                    if isHovering {
                        DocumentTabShape().fill(ZPDFColor.color(DocumentTabPalette.hover))
                    }
                }
                .contentShape(DocumentTabShape())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: DocumentTabMetrics.topRadius)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .fixedSize()
        .help(NSLocalizedString("Open a document in a new tab", comment: "New tab button help"))
        .accessibilityLabel(Text(NSLocalizedString(
            "New Tab",
            comment: "Accessibility label for the tab strip's new-tab button"
        )))
    }
}

/// The › menu listing the tabs the strip had no room for. Choosing one brings it to the front,
/// which also moves it into the strip.
struct DocumentTabOverflowMenu: View {

    let items: [DocumentTabItem]
    let model: DocumentTabBarModel

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(item.hasUnsavedChanges ? "• \(item.displayTitle)" : item.displayTitle) {
                    model.select(item.id)
                }
            }
        } label: {
            ZPDFGlyphView(.symbol(.chevronTrailing), size: ZPDFSpacing.Control.icon)
                .foregroundStyle(ZPDFColor.color(DocumentTabPalette.inactiveTitle))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: DocumentTabMetrics.overflowWidth, height: DocumentTabMetrics.height)
        .fixedSize()
        .help(Self.title(count: items.count))
        .accessibilityLabel(Text(Self.title(count: items.count)))
    }

    /// "2 more documents".
    static func title(count: Int) -> String {
        LocalizedPlural.string(
            "%lld more documents",
            count: count,
            one: NSLocalizedString("%lld more document", comment: "Tab strip overflow menu, singular"),
            other: NSLocalizedString("%lld more documents", comment: "Tab strip overflow menu, plural")
        )
    }
}

/// One tab.
struct DocumentTabView: View {

    let item: DocumentTabItem
    let model: DocumentTabBarModel
    /// The width the strip gives this tab.
    var width: CGFloat = DocumentTabMetrics.naturalWidth

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // Every inset and gap here is a ``DocumentTabMetrics`` constant, so the title room the
        // band plans with is the room the title is drawn in (L-24).
        //
        // L-106 (live test 8): the select button is the WHOLE tab. It used to end where the
        // close button's reserved frame began, so on a narrow back tab only the left half
        // selected: the right half was the close button's frame — invisible but, in the app's
        // SDK-14 hit-testing, still clickable, so it closed the tab — and the gaps around it,
        // where a click fell through to the band and started a window drag. "Clicking Plan-B
        // left Plan-A2 active." The close button now lies over the select button and exists
        // only while it shows (hovered, focused or front); the title keeps the same room
        // either way, so nothing reflows under the pointer (IM-136).
        let showsClose = Self.showsCloseButton(isHovering: isHovering, isFocused: isFocused, isActive: item.isActive)
        Button {
            model.select(item.id)
        } label: {
            HStack(spacing: DocumentTabMetrics.dotGap) {
                if item.hasUnsavedChanges {
                    // Before the name: a shape the eye finds without colour,
                    // spoken as "edited" through the accessibility value.
                    Circle()
                        .fill(ZPDFColor.color(DocumentTabPalette.unsavedDot))
                        .frame(width: DocumentTabMetrics.unsavedDot, height: DocumentTabMetrics.unsavedDot)
                }
                // The name has priority. The badge is offered only while the whole name still
                // fits beside it; otherwise the tab shows the name alone and the badge lives
                // in the tooltip.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ZPDFSpacing.s) {
                        title.fixedSize()
                        if let revisionLabel = item.revisionLabel {
                            badge(revisionLabel)
                        }
                    }
                    title
                }
            }
            .padding(.leading, DocumentTabMetrics.titleLeadingInset)
            // The close button's frame and its gaps stay out of the title's way whether or not
            // the button shows: the same room ``DocumentTabMetrics/titleRoom`` plans with.
            .padding(.trailing, Self.closeColumnWidth)
            // Leading-aligned in the full width rather than pushed by a Spacer: a Spacer
            // is a stack child, and the stack's gap before it cost the title 6 pt.
            .frame(width: width, height: DocumentTabMetrics.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .help(item.tooltip)
        .accessibilityLabel(Text(item.accessibilityLabel))
        .accessibilityValue(Text(item.accessibilityValue ?? ""))
        .accessibilityAddTraits(item.isActive ? [.isSelected, .isButton] : .isButton)
        .overlay(alignment: .trailing) {
            if showsClose {
                closeButton
                    .padding(.trailing, DocumentTabMetrics.trailingInset)
            }
        }
        .frame(width: width, height: DocumentTabMetrics.height)
        .background { DocumentTabGround(isActive: item.isActive, isHovering: isHovering) }
        .zpdfFocusRing(isFocused, cornerRadius: DocumentTabMetrics.topRadius)
        .contextMenu { contextMenu }
        .onHover { hovering in
            isHovering = hovering
            // The ✕ goes with the pointer; its own exit may never arrive once it is removed.
            if !hovering { isHoveringClose = false }
        }
        .zpdfAnimation(.micro, value: isHovering)
    }

    /// What the tab keeps clear at its trailing edge for the close button: the gap before it,
    /// its frame and the inset after it.
    static var closeColumnWidth: CGFloat {
        DocumentTabMetrics.closeGap + DocumentTabMetrics.closeWidth + DocumentTabMetrics.trailingInset
    }

    /// The ✕, laid over the select button while it shows.
    private var closeButton: some View {
        Button {
            model.close(item.id)
        } label: {
            ZPDFGlyphView(.symbol(.close), size: ZPDFSpacing.Control.iconSmall)
                .frame(
                    width: DocumentTabMetrics.closeWidth,
                    height: ZPDFSpacing.Control.minimumHitTarget
                )
                .background {
                    Circle()
                        .fill(ZPDFColor.color(DocumentTabPalette.hover))
                        .opacity(isHoveringClose ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ZPDFColor.color(
            item.isActive || isHoveringClose ? DocumentTabPalette.activeTitle : DocumentTabPalette.inactiveTitle
        ))
        .onHover { isHoveringClose = $0 }
        .help(Self.closeHelp)
        .accessibilityLabel(Text(String(
            format: NSLocalizedString(
                "Close %@",
                comment: "Accessibility label for a document tab's close button"
            ),
            item.displayTitle
        )))
    }

    private var title: some View {
        Self.titleText(item)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The tab's title as drawn: the name without its extension (L-24) in the tab title style.
    /// A test measures this exact view against ``DocumentTabMetrics/titleRoom(tabWidth:hasUnsavedDot:)``.
    static func titleText(_ item: DocumentTabItem) -> some View {
        Text(item.tabTitle)
            .zpdfText(
                item.isActive ? .cardTitle.withWeight(.medium) : .cardTitle.withWeight(.regular),
                item.isActive ? DocumentTabPalette.activeTitle : DocumentTabPalette.inactiveTitle
            )
    }

    private func badge(_ label: String) -> some View {
        Text(label)
            .zpdfText(.monoNumeric.withSize(10), DocumentTabPalette.inactiveTitle)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, ZPDFSpacing.xs)
            .padding(.vertical, 1)
            .zpdfControlBackground(
                fill: DocumentTabPalette.badgeFill,
                stroke: DocumentTabPalette.badgeStroke,
                cornerRadius: ZPDFRadius.label
            )
    }

    /// Whether the close button is visible and clickable. Its space is reserved either way.
    static func showsCloseButton(isHovering: Bool, isFocused: Bool, isActive: Bool) -> Bool {
        isHovering || isFocused || isActive
    }

    /// The close button's hover help, with the shortcut it shares with File ▸ Close.
    static var closeHelp: String {
        let base = NSLocalizedString("Close this document", comment: "Document tab close button help")
        // The table in force, the person's overrides included (R-074); `.standard` ignored them.
        guard let binding = ZPDFCommandTable.effective.command(.closeTab)?.binding?.displayString,
              !binding.isEmpty else { return base }
        return "\(base) (\(binding))"
    }

    /// The tab's context menu (IM-135): common tab actions without the menu bar. Items whose
    /// hook is not wired, or that need a saved file, are left out rather than shown inert.
    @ViewBuilder
    private var contextMenu: some View {
        Button(NSLocalizedString("Close", comment: "Document tab context menu: close this tab")) {
            model.close(item.id)
        }
        Button(NSLocalizedString("Close Other Tabs", comment: "Document tab context menu: close every other tab")) {
            model.closeOthers(keeping: item.id)
        }
        .disabled(model.items.count < 2)
        if let url = item.fileURL {
            Divider()
            if let reveal = model.onRevealInFinder {
                Button(NSLocalizedString("Reveal in Finder", comment: "Document tab context menu")) {
                    reveal(url)
                }
            }
            if let copy = model.onCopyPath {
                Button(NSLocalizedString("Copy Path", comment: "Document tab context menu: copy the file's path")) {
                    copy(url)
                }
            }
        }
    }
}

/// Drag to reorder (NL-DOCS-14): a tab dragged onto another takes its place. Only when the app
/// wired ``DocumentTabBarModel/onMoveTab``.
struct DocumentTabDragModifier: ViewModifier {
    let item: DocumentTabItem
    let model: DocumentTabBarModel

    func body(content: Content) -> some View {
        if model.onMoveTab != nil {
            content
                .draggable(DocumentTabBarModel.dragPayload(for: item.id)) {
                    Text(item.tabTitle)
                        .zpdfText(.control, .textPrimary)
                        .padding(ZPDFSpacing.s)
                }
                .dropDestination(for: String.self) { payloads, _ in
                    guard let dragged = payloads.lazy.compactMap(DocumentTabBarModel.draggedTab(in:)).first else { return false }
                    model.moveTab(dragged, onto: item.id)
                    return true
                }
        } else {
            content
        }
    }
}

#if DEBUG
struct DocumentTabBar_Previews: PreviewProvider {
    static var previews: some View {
        let environment = ProjectShellEnvironment.mock()
        return DocumentTabBarView(model: environment.tabBar)
            .frame(width: 300, height: 38)
    }
}
#endif
