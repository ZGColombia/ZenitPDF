import SwiftUI
import ZPDFDesignSystem

/// The Navigator's section switcher, drawn as the 2026-09-23 mockup draws it: a rounded strip of
/// **labeled** tabs — `Pages · Layers · Zones · Search` — sharing the width, the active tab
/// filled with the selected-segment blue and underlined in the accent. Never bare icons.
///
/// The active state is a fill, an underline (a shape), a weight change and the `isSelected`
/// trait, so it survives greyscale and Increase Contrast. Left/Right arrows move the selection
/// while the switcher has focus, matching `ZPDFSegmentedControl`'s keyboard grammar.
struct NavigatorSwitcher: View {

    @Binding var selection: NavigatorSection
    /// The segments: `NavigatorSidebar.segments`, the mockup's four. Open Drawings is not a
    /// segment; it opens from the file header's ⋯ menu, and while it is
    /// showing no segment is selected.
    var sections: [NavigatorSection] = NavigatorSidebar.segments

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    /// How a tab is painted, as a value, so tests can pin "the selected tab is filled and
    /// underlined in the accent" without rendering.
    struct TabAppearance: Equatable {
        /// The ground under the tab, if any.
        var base: ZPDFColorToken?
        /// The accent wash over the ground, if any.
        var tint: ZPDFColorToken?
        var tintOpacity: Double
        /// The underline colour, if any.
        var underline: ZPDFColorToken?
        /// The label colour.
        var text: ZPDFColorToken
        /// Whether the label is drawn semibold.
        var isEmphasised: Bool
    }

    /// The paint for one tab.
    static func tabAppearance(isSelected: Bool, isHovered: Bool) -> TabAppearance {
        if isSelected {
            return TabAppearance(
                base: NavigatorStyle.selectedTabFill,
                tint: nil,
                tintOpacity: 0,
                underline: NavigatorStyle.indicator,
                text: .textPrimary,
                isEmphasised: true
            )
        }
        return TabAppearance(
            base: nil,
            tint: isHovered ? NavigatorStyle.hover : nil,
            // The hover token is translucent by definition; it is composited as it stands.
            tintOpacity: isHovered ? 1 : 0,
            underline: nil,
            text: isHovered ? .textPrimary : .textSecondary,
            isEmphasised: false
        )
    }

    var body: some View {
        NavigatorTabStripLayout(spacing: 2) {
            ForEach(sections) { section in
                NavigatorSwitcherTab(
                    section: section,
                    isSelected: section == selection
                ) {
                    selection = section
                }
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .zpdfControlBackground(
            fill: NavigatorStyle.panelFill,
            stroke: NavigatorStyle.panelEdge,
            cornerRadius: NavigatorStyle.tabRadius + 2
        )
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: NavigatorStyle.tabRadius + 2)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Navigator page",
            comment: "Accessibility label for the navigator section switcher"
        )))
        .zpdfAnimation(NavigatorStyle.motion, value: selection)
    }

    private func move(_ direction: MoveCommandDirection) {
        // From Open Drawings, which has no segment, an arrow lands on the first segment.
        guard let index = sections.firstIndex(of: selection) else {
            if let first = sections.first { selection = first }
            return
        }
        switch direction {
        case .left:
            if index > 0 { selection = sections[index - 1] }
        case .right:
            if index < sections.count - 1 { selection = sections[index + 1] }
        default:
            break
        }
    }
}

/// One tab of the switcher, with its own hover state.
private struct NavigatorSwitcherTab: View {

    let section: NavigatorSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = NavigatorSwitcher.tabAppearance(isSelected: isSelected, isHovered: isHovered)
        let shape = RoundedRectangle(cornerRadius: NavigatorStyle.tabRadius, style: .continuous)
        Button(action: action) {
            Text(section.switcherTitle)
                .zpdfText(
                    (look.isEmphasised ? ZPDFTextStyle.tabSelected : .tab).withSize(NavigatorStyle.segmentLabelSize),
                    look.text
                )
                .lineLimit(1)
                // Four labels at 13 pt fit the default width; at the 180 pt minimum a label
                // shrinks a little before it truncates (see `NavigatorTabStripLayout`).
                .minimumScaleFactor(0.8)
                .padding(.horizontal, NavigatorTabStripLayout.tabPadding)
                .frame(maxWidth: .infinity)
                // The track's 2 pt inset on each side keeps the strip at the mockup's height.
                .frame(height: NavigatorStyle.tabHeight - 4)
                .background {
                    ZStack {
                        if let base = look.base { shape.fill(ZPDFColor.color(base)) }
                        if let tint = look.tint { shape.fill(ZPDFColor.color(tint).opacity(look.tintOpacity)) }
                    }
                }
                .overlay(alignment: .bottom) {
                    // The mockup's active-tab underline.
                    if let underline = look.underline {
                        Capsule()
                            .fill(ZPDFColor.color(underline))
                            .frame(height: NavigatorStyle.tabUnderline)
                            .padding(.horizontal, ZPDFSpacing.xs)
                    }
                }
                .contentShape(shape)
                // A landmark for the off-screen click probe (L-108); it never takes a click.
                .zpdfMarker(section.markerIdentifier)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ZPDFMotion.animation(.micro, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .help(section.helpText)
        .accessibilityLabel(Text(section.displayName))
        // The help text is documented as the VoiceOver hint too, and now it is one (IM-219).
        .accessibilityHint(Text(section.helpText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Lays the tabs out across the strip's width in proportion to their labels.
///
/// With room to spare every tab gets its label's width plus an equal share of the rest, so the
/// four tabs read as the mockup's even strip. Without room — the Navigator dragged to its
/// 180 pt minimum — each label is scaled down by the same factor, so no tab is truncated while
/// another wastes space beside it. The labels' own minimum scale factor absorbs the difference.
struct NavigatorTabStripLayout: Layout {

    var spacing: CGFloat = 2

    /// Each tab's horizontal padding, per side. It is never scaled: only the label shrinks.
    static let tabPadding: CGFloat = ZPDFSpacing.xs

    /// The widths the tabs get, given their ideal widths (label plus `fixed` padding each) and
    /// the width on offer. When tight, only the label part scales, so a label keeps as much of
    /// its size as the strip allows. Static so the rule is testable without a view tree.
    static func widths(
        ideal: [CGFloat],
        available: CGFloat,
        spacing: CGFloat,
        fixed: CGFloat = 2 * tabPadding
    ) -> [CGFloat] {
        guard !ideal.isEmpty else { return [] }
        let count = CGFloat(ideal.count)
        let room = max(0, available - spacing * (count - 1))
        let total = ideal.reduce(0, +)
        guard total > 0 else { return Array(repeating: room / count, count: ideal.count) }
        if total <= room {
            let extra = (room - total) / count
            return ideal.map { $0 + extra }
        }
        let labels = ideal.map { max(0, $0 - fixed) }
        let labelTotal = labels.reduce(0, +)
        let labelRoom = max(0, room - fixed * count)
        guard labelTotal > 0 else { return Array(repeating: room / count, count: ideal.count) }
        let scale = labelRoom / labelTotal
        return labels.map { $0 * scale + fixed }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        let natural = ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.widths(ideal: ideal, available: bounds.width, spacing: spacing)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }
}
