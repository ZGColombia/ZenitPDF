import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Sections, as values

/// One open drawing's section in the Pages list: a header row, then — when it is the drawing on
/// screen and not collapsed — its page cards.
///
/// LT3-11 (2026-09-23): all open drawings must be visible in the list, as they were before the
/// design round. The design round had moved the open-drawings list behind
/// the file header's ⋯ menu, so with two drawings open the Navigator showed one. Every open
/// drawing now has a visible section in Pages, in tab order.
struct NavigatorDrawingSection: Equatable, Identifiable {
    let tab: DocumentTabSummary
    /// Whether this is the drawing on screen.
    let isActive: Bool
    /// Whether its page cards are shown. Only the drawing on screen has its pages loaded, so a
    /// back drawing's section is its header; clicking it brings the drawing to the front, where
    /// it opens.
    let isExpanded: Bool

    var id: UUID { tab.id }

    /// The sections for `tabs`, in tab order: every open drawing exactly once, the front one
    /// expanded unless the person collapsed it.
    static func sections(
        tabs: [DocumentTabSummary],
        activeID: UUID?,
        collapsed: Set<UUID>
    ) -> [NavigatorDrawingSection] {
        var seen: Set<UUID> = []
        return tabs.compactMap { tab in
            guard seen.insert(tab.id).inserted else { return nil }
            let isActive = tab.id == activeID
            return NavigatorDrawingSection(
                tab: tab,
                isActive: isActive,
                isExpanded: isActive && !collapsed.contains(tab.id)
            )
        }
    }

    /// What a click on the header does: a back drawing comes to the front; the front drawing
    /// folds or unfolds.
    enum HeaderClick: Equatable {
        case switchTo(UUID)
        case toggle(UUID)
    }

    var headerClick: HeaderClick { isActive ? .toggle(tab.id) : .switchTo(tab.id) }

    /// The header's spoken value: expanded or collapsed, plus "edited" for unsaved work.
    var accessibilityValue: String {
        let state = isExpanded
            ? NSLocalizedString("Expanded", comment: "Accessibility value: a drawing section in the Pages list is open")
            : NSLocalizedString("Collapsed", comment: "Accessibility value: a drawing section in the Pages list is closed")
        guard tab.hasUnsavedChanges else { return state }
        return String(
            format: NSLocalizedString("%1$@, edited", comment: "Accessibility value: section state, then unsaved"),
            state
        )
    }

    /// The header's hover help and VoiceOver hint.
    var hint: String {
        isActive
            ? (isExpanded
                ? NSLocalizedString("Hide the pages of this drawing", comment: "Pages list drawing header help: collapse")
                : NSLocalizedString("Show the pages of this drawing", comment: "Pages list drawing header help: expand"))
            : NSLocalizedString("Switch to this drawing", comment: "Pages list drawing header help: bring a back drawing to the front")
    }
}

// MARK: - Header view

/// A drawing section's header: disclosure chevron, unsaved dot, name, page count, ⋯ menu.
struct NavigatorDrawingSectionHeader: View {

    let environment: ProjectShellEnvironment
    let panelState: ShellPanelState?
    let section: NavigatorDrawingSection
    let onClick: (NavigatorDrawingSection.HeaderClick) -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tab = section.tab
        HStack(spacing: ZPDFSpacing.xs) {
            Button {
                onClick(section.headerClick)
            } label: {
                HStack(spacing: ZPDFSpacing.xs) {
                    ZPDFGlyphView(
                        .symbol(section.isExpanded ? .chevronDown : .chevronTrailing),
                        size: ZPDFSpacing.Control.iconSmall
                    )
                    .foregroundStyle(ZPDFColor.color(.textSecondary))
                    .frame(width: ZPDFSpacing.l)
                    if tab.hasUnsavedChanges {
                        Circle()
                            .fill(ZPDFColor.color(NavigatorStyle.indicator))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(tab.title)
                        .zpdfText(
                            section.isActive ? .rowLabel.withWeight(.semibold) : .rowLabel.withWeight(.medium),
                            section.isActive ? .textPrimary : .textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    if tab.pageCount > 0 {
                        Text(NavigatorDrawingsList.pageCountText(tab.pageCount))
                            .zpdfText(.rowLabel, .textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .zpdfFocusRing(isFocused, cornerRadius: NavigatorStyle.cardRadius)
            .help(NavigatorFileHeader.tooltip(title: tab.title, fileName: tab.fileName))
            .accessibilityLabel(Text(tab.accessibilityLabel))
            .accessibilityValue(Text(section.accessibilityValue))
            .accessibilityHint(Text(section.hint))
            .accessibilityAddTraits(section.isActive ? [.isHeader, .isSelected, .isButton] : [.isHeader, .isButton])

            NavigatorMoreMenu(
                accessibilityLabel: NavigatorFileAction.menuLabel,
                hint: NavigatorFileAction.menuHint(for: tab.title)
            ) {
                if section.isActive {
                    NavigatorSetActionsMenu(environment: environment, actions: Self.setActions(for: section, in: environment))
                    let actions = NavigatorFileAction.offered(openDrawings: environment.document.tabs.count)
                        .filter { $0 != .showOpenDrawings }
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
                } else {
                    Button {
                        environment.tabBar.onSelect?(tab.id)
                    } label: {
                        Label {
                            Text(Self.showTitle)
                        } icon: {
                            ZPDFGlyphView(.symbol(.open), size: ZPDFSpacing.Control.icon)
                        }
                    }
                    Divider()
                    // The tab's own close hook, so unsaved work still asks before it goes.
                    Button {
                        environment.tabBar.close(tab.id)
                    } label: {
                        Label {
                            Text(NavigatorFileAction.close.title)
                        } icon: {
                            ZPDFGlyphView(NavigatorFileAction.close.glyph, size: ZPDFSpacing.Control.icon)
                        }
                    }
                }
            }
        }
        .padding(.leading, ZPDFSpacing.s)
        .padding(.trailing, ZPDFSpacing.xs)
        .frame(height: NavigatorStyle.fileHeaderHeight)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: NavigatorStyle.cardRadius, style: .continuous)
                    .fill(ZPDFColor.color(NavigatorStyle.hover))
            }
        }
        .onHover { hovering in
            withAnimation(ZPDFMotion.animation(.micro, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .accessibilityElement(children: .contain)
    }

    /// The drawing-set items this header's ⋯ menu offers: the active drawing's, none on a
    /// drawing behind it (R-071).
    @MainActor
    static func setActions(for section: NavigatorDrawingSection, in environment: ProjectShellEnvironment) -> [NavigatorSetAction] {
        section.isActive ? NavigatorSetAction.offered(in: environment) : []
    }

    /// The back drawing's ⋯ item that brings it to the front.
    static var showTitle: String {
        NSLocalizedString("Show Drawing", comment: "Pages list: bring a back drawing to the front")
    }
}
