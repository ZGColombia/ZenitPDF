import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// The ledger bar's summary strip. The chips themselves are the design system's
// ZPDFSummaryChip; what lives here is the mapping from a quantity kind to its glyph and ink,
// and the rounded group with hairline separators the mockup draws around the four chips.

extension LedgerSummary.Kind {

    /// The chip's glyph: the measurement icon a person already knows from the tool group.
    var glyph: ZPDFGlyph {
        switch self {
        case .areas: return .measurement(.area)
        case .lengths: return .measurement(.length)
        case .counts: return .measurement(.count)
        case .markups: return .symbol(.callout)
        }
    }

    /// The glyph's ink, the mockup's colour language: the markup inks the page itself uses —
    /// blue for the two measured quantities, green for counts, red for markups. Decorative
    /// only: the title carries the meaning, so nothing here relies on colour.
    var ink: ZPDFColorToken {
        switch self {
        case .areas, .lengths: return .inkBlue
        case .counts: return .inkGreen
        case .markups: return .inkRed
        }
    }
}

/// The ledger bar's summary: one chip per quantity kind, in one rounded group with hairline
/// separators between the chips (the mockup's Areas · Lengths · Counts · Markups strip).
///
/// NL-UX-09: with `onChip` set, each chip is a button that filters the ledger to its kind —
/// Areas, Lengths, Counts; Markups clears it — and the active one is drawn selected. Without it
/// the chips stay read-outs, with no hover state inviting a click that does nothing.
struct LedgerSummaryStrip: View {

    let summary: LedgerSummary
    /// What a click on a chip does; `nil` keeps the chips read-only.
    var onChip: ((LedgerSummary.Kind) -> Void)?
    /// The kind the ledger is filtered to, drawn selected.
    var activeKind: LedgerSummary.Kind?

    /// A compact strip shows only each chip's glyph and headline, for a narrow window.
    var isCompact = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(summary.chips.enumerated()), id: \.element.id) { index, chip in
                if index > 0 {
                    ZPDFHairlineDivider(axis: .vertical)
                        .padding(.vertical, ZPDFSpacing.m)
                }
                if isCompact {
                    // V-048: the one-line chip keeps the filter's selected state and its click, so
                    // narrowing the window never hides which kind the ledger shows or the way back.
                    LedgerCompactSummaryChip(
                        chip: chip,
                        isSelected: Self.isSelected(chip.kind, activeKind: activeKind),
                        action: onChip.map { handler in { handler(chip.kind) } }
                    )
                    .help(Self.chipHelp(chip.kind, isInteractive: onChip != nil))
                } else {
                    ZPDFSummaryChip(
                        glyph: chip.kind.glyph,
                        tint: chip.kind.ink,
                        title: chip.kind.title,
                        count: chip.displayCount,
                        total: chip.displayTotal,
                        isSelected: Self.isSelected(chip.kind, activeKind: activeKind),
                        action: onChip.map { handler in { handler(chip.kind) } }
                    )
                    .help(Self.chipHelp(chip.kind, isInteractive: onChip != nil))
                    // The unit spoken in full ("square feet"), not read as its symbol.
                    .accessibilityLabel(Text(chip.accessibilityLabel))
                }
            }
        }
        .frame(height: ZPDFSpacing.Chrome.summaryChipHeight)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .fill(ZPDFColor.elevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Quantity summary",
            comment: "Accessibility label of the ledger bar's summary chips"
        )))
    }

    /// Whether a chip draws selected: the kind the ledger is filtered to. Markups never does —
    /// it is the chip that clears the filter. One rule for the full and the compact chip.
    static func isSelected(_ kind: LedgerSummary.Kind, activeKind: LedgerSummary.Kind?) -> Bool {
        activeKind == kind && kind != .markups
    }

    /// A chip's tooltip: what a click does, or nothing for a read-out.
    static func chipHelp(_ kind: LedgerSummary.Kind, isInteractive: Bool) -> String {
        guard isInteractive else { return "" }
        return kind == .markups
            ? NSLocalizedString("Show every row", comment: "Help on the Markups summary chip: clears the kind filter")
            : String(
                format: NSLocalizedString(
                    "Show only %@. Click again to show every row.",
                    comment: "Help on a summary chip that filters the ledger to one quantity kind; the kind"
                ),
                kind.title
            )
    }
}

/// One line per chip for a narrow window: glyph, title and headline, with the full chip's
/// selected paint and click (V-048). It used to be a bare read-out, so after Areas was clicked a
/// narrow window showed no sign of the filter and no chip to turn it off.
struct LedgerCompactSummaryChip: View {

    let chip: LedgerSummary.Chip
    let isSelected: Bool
    /// What a click does; `nil` keeps the chip a read-out.
    let action: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// The chip's paint: the design system's summary-chip paint, so the compact and the full chip
    /// draw one selected state (a filled shape, not only a tint).
    static func paint(isSelected: Bool, isHovering: Bool, isInteractive: Bool) -> ZPDFControlPaint {
        ZPDFSummaryChip.paint(isSelected: isSelected, isHovering: isHovering, isInteractive: isInteractive)
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($isFocused)
                    .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.card)
                    .onHover { isHovering = $0 }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(chip.accessibilityLabel))
        .zpdfAnimation(.micro, value: isHovering)
    }

    private var content: some View {
        let paint = Self.paint(isSelected: isSelected, isHovering: isHovering, isInteractive: action != nil)
        return HStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(chip.kind.glyph, size: ZPDFSpacing.Control.icon)
                .foregroundStyle(ZPDFColor.color(chip.kind.ink))
            Text(chip.kind.title).zpdfText(.chipTitle, .textSecondary)
            Text(chip.headline).zpdfText(.chipValue, paint.foreground)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(maxHeight: .infinity)
        .background { ZPDFPaintedBackground(paint, cornerRadius: ZPDFRadius.card) }
        .contentShape(RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous))
    }
}

/// Quantities | History as the mockup draws them: no fill and no track — the selected
/// tab is a white, heavier label over the 2 pt accent underline, the other a secondary label.
/// (The navigator's and inspector's filled tabs are a different control; the ledger's sit
/// directly on the bar.) The underline is a shape, and the label weight changes too, so the
/// state survives greyscale; hover lays the design system's hover overlay under the label.
struct LedgerPaneTabBar<Value: Hashable>: View {

    struct Tab: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let tabs: [Tab]
    let accessibilityTitle: String

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ForEach(tabs) { tab in
                LedgerPaneTabButton(title: tab.title, isSelected: tab.value == selection) {
                    selection = tab.value
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityTitle))
    }
}

/// One ledger tab; `isSelected` paints only the label and the underline, never a ground.
struct LedgerPaneTabButton: View {

    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// The ground behind the tab: none when selected, the hover overlay otherwise.
    static func groundToken(isSelected: Bool, isHovering: Bool) -> ZPDFColorToken? {
        guard !isSelected else { return nil }
        return ZPDFInteractionState.resolve(isHovering: isHovering, isPressed: false).overlay
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .zpdfText(isSelected ? .tabSelected : .tab, isSelected ? .textPrimary : .textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, ZPDFSpacing.l)
                .frame(height: ZPDFSpacing.Chrome.segmentedTabHeight)
                .background {
                    if let token = Self.groundToken(isSelected: isSelected, isHovering: isHovering) {
                        shape.fill(ZPDFColor.color(token))
                    }
                }
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: ZPDFSpacing.Chrome.tabIndicatorHeight / 2, style: .continuous)
                        .fill(ZPDFColor.accentBlue)
                        .frame(height: ZPDFSpacing.Chrome.tabIndicatorHeight)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .zpdfFocusRing(isFocused)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .zpdfAnimation(.quick, value: isSelected)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
