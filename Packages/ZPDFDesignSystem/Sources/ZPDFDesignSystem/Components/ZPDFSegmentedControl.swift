import SwiftUI

/// A compact segmented control for mutually exclusive modes.
///
/// Left/Right arrow keys move the selection while the control has focus, and the selected
/// segment is marked with a shape change plus the `isSelected` trait, not just a tint.
public struct ZPDFSegmentedControl<Value: Hashable>: View {

    /// One choice in the control.
    public struct Segment: Identifiable {
        public let value: Value
        public let title: String
        public let glyph: ZPDFGlyph?
        public let helpText: String?

        public var id: Value { value }

        public init(value: Value, title: String, glyph: ZPDFGlyph? = nil, helpText: String? = nil) {
            self.value = value
            self.title = title
            self.glyph = glyph
            self.helpText = helpText
        }
    }

    /// The two sizes the control comes in.
    public enum Style: Sendable, Hashable {
        /// 24 pt, inside toolbars, sheets and option rows.
        case compact
        /// 36 pt panel tabs from the 2026-09-23 mockup: navigator (Pages / Layers / Zones /
        /// Search), inspector (Markup / Properties / Comments) and ledger (Quantities / History).
        case tabs

        var height: CGFloat {
            switch self {
            case .compact: return ZPDFSpacing.Control.toolbarControl
            case .tabs: return ZPDFSpacing.Chrome.segmentedTabHeight
            }
        }

        var isCompact: Bool { self == .compact }
    }

    private let segments: [Segment]
    private let accessibilityTitle: String
    private let style: Style
    @Binding private var selection: Value

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var hovered: Value?

    public init(
        selection: Binding<Value>,
        segments: [Segment],
        accessibilityTitle: String,
        style: Style = .compact
    ) {
        self._selection = selection
        self.segments = segments
        self.accessibilityTitle = accessibilityTitle
        self.style = style
    }

    public var body: some View {
        HStack(spacing: style.isCompact ? 0 : 2) {
            ForEach(segments) { segment in
                segmentView(segment)
            }
        }
        .padding(style.isCompact ? 1 : 2)
        .background {
            ZPDFPaintedBackground(
                ZPDFControlPaints.tabTrack(compact: style.isCompact),
                cornerRadius: style.isCompact ? ZPDFRadius.medium : ZPDFRadius.card
            )
        }
        .frame(height: style.height)
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: style.isCompact ? ZPDFRadius.medium : ZPDFRadius.card)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .zpdfAnimation(.quick, value: selection)
        .zpdfAnimation(.micro, value: hovered)
    }

    /// The paint for one segment in its current state.
    func paint(for segment: Segment, isPressed: Bool = false) -> ZPDFControlPaint {
        ZPDFControlPaints.tab(
            isSelected: segment.value == selection,
            state: .resolve(isHovering: hovered == segment.value, isPressed: isPressed, isEnabled: isEnabled),
            isEnabled: isEnabled,
            compact: style.isCompact
        )
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        let restPaint = paint(for: segment)
        Button {
            selection = segment.value
        } label: {
            HStack(spacing: ZPDFSpacing.xs) {
                if let glyph = segment.glyph {
                    ZPDFGlyphView(glyph, size: ZPDFSpacing.Control.iconSmall)
                }
                Text(segment.title)
                    .zpdfFont(restPaint.textStyle)
                    .lineLimit(1)
            }
            .padding(.horizontal, style.isCompact ? ZPDFSpacing.m : ZPDFSpacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ZPDFIndicatorBar(token: restPaint.indicator, inset: style.isCompact ? ZPDFSpacing.m : 0)
            }
            .background {
                if isSelected && !style.isCompact {
                    // The mockup's selected tab glows faintly toward its indicator bar.
                    LinearGradient(
                        colors: [ZPDFColor.color(.accentBlue, opacity: 0), ZPDFColor.color(.accentBlue, opacity: 0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(ZPDFPaintedButtonStyle(
            ZPDFControlPaintSet { state in
                ZPDFControlPaints.tab(isSelected: isSelected, state: state, isEnabled: isEnabled, compact: style.isCompact)
            },
            cornerRadius: style.isCompact ? ZPDFRadius.small : ZPDFRadius.control,
            isHovering: hovered == segment.value,
            isEnabled: isEnabled
        ))
        .onHover { inside in
            if inside { hovered = segment.value } else if hovered == segment.value { hovered = nil }
        }
        .help(segment.helpText ?? segment.title)
        .accessibilityLabel(segment.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let index = segments.firstIndex(where: { $0.value == selection }) else { return }
        switch direction {
        case .left:
            if index > 0 { selection = segments[index - 1].value }
        case .right:
            if index < segments.count - 1 { selection = segments[index + 1].value }
        default:
            break
        }
    }
}

#if DEBUG
struct ZPDFSegmentedControl_Previews: PreviewProvider {
    private enum Mode: String, Hashable { case zones, layers, pages }

    private struct Demo: View {
        @State private var mode: Mode = .zones

        var body: some View {
            ZPDFPreviewPanel("Segmented control") {
                ZPDFSegmentedControl(
                    selection: $mode,
                    segments: [
                        .init(value: Mode.pages, title: NSLocalizedString("Pages", comment: "Preview label"), glyph: .symbol(.pages)),
                        .init(value: Mode.layers, title: NSLocalizedString("Layers", comment: "Preview label"), glyph: .symbol(.layers)),
                        .init(value: Mode.zones, title: NSLocalizedString("Zones", comment: "Preview label"), glyph: .symbol(.projectZones))
                    ],
                    accessibilityTitle: NSLocalizedString("Navigator section", comment: "Preview label")
                )
                ZPDFSegmentedControl(
                    selection: $mode,
                    segments: [
                        .init(value: Mode.pages, title: NSLocalizedString("Pages", comment: "Preview label")),
                        .init(value: Mode.layers, title: NSLocalizedString("Layers", comment: "Preview label")),
                        .init(value: Mode.zones, title: NSLocalizedString("Zones", comment: "Preview label"))
                    ],
                    accessibilityTitle: NSLocalizedString("Navigator section", comment: "Preview label")
                )
                .disabled(true)
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFSegmentedControl - dark and light")
    }
}
#endif
