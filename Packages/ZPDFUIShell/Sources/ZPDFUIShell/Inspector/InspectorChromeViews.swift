import SwiftUI
import ZPDFDesignSystem

/// The panel's title band: "INSPECTOR" in letter-spaced caps and the close control.
struct InspectorTitleBand: View {

    let closeKeyboardHint: String?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Inspector", comment: "Inspector panel title"))
                .zpdfText(.panelTitle, .textPrimary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ZPDFSpacing.s)
            ZPDFToolbarButton(
                glyph: .symbol(.close),
                title: NSLocalizedString("Close Inspector", comment: "Inspector header close control"),
                keyboardHint: closeKeyboardHint,
                action: onClose
            )
        }
        .padding(.leading, ZPDFSpacing.l)
        .padding(.trailing, ZPDFSpacing.s)
        .frame(height: InspectorMetrics.titleBand)
    }
}

/// Markup · Properties · Comments, as the mockup draws them: equal-width tabs, the selected
/// one on a raised fill with an accent underline.
///
/// One keyboard stop; Left and Right move between tabs. The selected tab carries the
/// `isSelected` trait and a heavier weight as well as the fill, so the state never rests on
/// colour alone.
struct InspectorTabStrip: View {

    @Binding var selection: InspectorTab

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { tab in
                InspectorTabButton(tab: tab, selection: selection) { selection = tab }
            }
        }
        .frame(height: InspectorMetrics.tabHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ZPDFColor.color(InspectorChrome.hairline))
                .frame(height: ZPDFStroke.hairline)
        }
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .onMoveCommand { direction in
            if let next = Self.tab(after: selection, moving: direction) { selection = next }
        }
        .zpdfAnimation(.quick, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Inspector page", comment: "Accessibility label of the Inspector's Markup / Properties / Comments tabs"
        )))
    }

    /// The tab an arrow key moves to, or `nil` at either end. Value-only, for tests.
    static func tab(after current: InspectorTab, moving direction: MoveCommandDirection) -> InspectorTab? {
        let all = InspectorTab.allCases
        guard let index = all.firstIndex(of: current) else { return nil }
        switch direction {
        case .left: return index > all.startIndex ? all[all.index(before: index)] : nil
        case .right: return all.index(after: index) < all.endIndex ? all[all.index(after: index)] : nil
        default: return nil
        }
    }
}

private struct InspectorTabButton: View {

    let tab: InspectorTab
    /// The strip's selected tab: this button's selected look, and the moment its hover plate is
    /// taken down (L-90).
    let selection: InspectorTab
    let action: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool { tab == selection }

    var body: some View {
        Button(action: action) {
            Text(tab.title)
                .zpdfText(
                    isSelected ? .tabSelected : .tab,
                    isSelected || isHovering ? .textPrimary : .textSecondary
                )
                .lineLimit(1)
                // A longer translation, or a larger text size, shrinks a little before it
                // truncates (L-14); English fits at the minimum width unscaled.
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: ZPDFRadius.control,
                        topTrailingRadius: ZPDFRadius.control,
                        style: .continuous
                    )
                    .fill(ZPDFColor.color(isSelected ? InspectorChrome.selectedFill : InspectorChrome.hover))
                    .opacity(isSelected || isHovering ? 1 : 0)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ZPDFColor.color(InspectorChrome.accentLine))
                        .frame(height: InspectorMetrics.tabUnderline)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
                // A landmark for the off-screen click probe (L-90); it never takes a click.
                .zpdfMarker(tab.markerIdentifier)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        // A change of page takes every hover plate down. AppKit reports the pointer leaving a
        // tab only when it moves; a pointer put somewhere else without moving — automation,
        // a tablet, a click right after a warp — left the tab it last rested on painted. Live
        // test 8 clicked Comments, posted a reply, then clicked Properties: Properties took the
        // selection and the page, and Comments kept the hover plate and the primary text colour,
        // so two tabs looked chosen ("the selection went to the Comments tab", L-90). Measured
        // in zpdf-hit-probe [inspector tabs after a reply]. The next real pointer move puts the
        // plate back where the pointer is.
        .onChange(of: selection) { isHovering = false }
        .zpdfAnimation(.micro, value: isHovering)
        .help(tab.helpText)
        .accessibilityLabel(Text(tab.title))
        .accessibilityHint(Text(tab.helpText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The header card: the accent tile with the markup's glyph, the type as the title, the
/// subject and page beneath, and a ⋯ menu of what can be done to the selection.
struct InspectorHeaderCard<MenuContent: View>: View {

    let model: InspectorHeaderModel
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHoveringMenu = false

    var body: some View {
        HStack(alignment: .center, spacing: ZPDFSpacing.l) {
            RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                .fill(ZPDFColor.color(InspectorChrome.accentFill))
                .frame(width: InspectorMetrics.tile, height: InspectorMetrics.tile)
                .overlay {
                    ZPDFGlyphView(model.glyph, size: ZPDFSpacing.Control.iconLarge)
                        .foregroundStyle(ZPDFColor.color(InspectorChrome.onAccent))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Two lines before truncation (L-14): "True Sloped Area Measurement" is wider
                // than the card at any sensible Inspector width.
                Text(model.title)
                    .zpdfText(.cardTitle, .textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .zpdfText(.caption, .textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The hover plate is drawn outside the menu: a macOS menu label keeps only its
            // text and image, so a background inside it would be dropped.
            Menu {
                menu()
            } label: {
                ZPDFGlyphView(.symbol(.more), size: ZPDFSpacing.Control.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(ZPDFColor.color(isHoveringMenu ? .textPrimary : .textSecondary))
            .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
                    .fill(ZPDFColor.color(InspectorChrome.hover))
                    .opacity(isHoveringMenu ? 1 : 0)
            }
            .onHover { isHoveringMenu = $0 }
            .zpdfAnimation(.micro, value: isHoveringMenu)
            .help(NSLocalizedString("Markup Actions", comment: "Inspector header card menu help"))
            .accessibilityLabel(Text(NSLocalizedString(
                "Markup Actions", comment: "Accessibility label of the Inspector header card's more menu"
            )))
        }
        .padding(.horizontal, InspectorMetrics.cardPadding)
        .padding(.vertical, ZPDFSpacing.m)
        // The mockup's raised card: the selected-card tone with a hairline edge.
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .fill(ZPDFColor.color(InspectorChrome.raisedCard))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .strokeBorder(ZPDFColor.color(InspectorChrome.hairline), lineWidth: ZPDFStroke.regular)
        }
    }
}
