import SwiftUI
import ZPDFUIPresentation

/// The heading band at the top of a navigator section, an inspector section or a docked panel.
///
/// Optionally acts as a disclosure control. When it does, the whole band is one keyboard
/// target, the chevron rotates (or simply swaps, under Reduce Motion), and the expanded state
/// is exposed as an accessibility value.
public struct ZPDFPanelHeader<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let count: Int?
    private let isExpanded: Binding<Bool>?
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - title: the section name.
    ///   - subtitle: optional secondary line, e.g. the active scale.
    ///   - count: optional item count shown as a quiet numeric badge.
    ///   - isExpanded: pass a binding to make the header a disclosure control.
    ///   - accessory: trailing controls, e.g. an add button or an overflow menu.
    public init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.isExpanded = isExpanded
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            if isExpanded != nil {
                disclosureButton
            }
            VStack(alignment: .leading, spacing: 0) {
                // One line, truncated at the end: squeezed by its accessories, the title used to
                // wrap a letter or two per line — "MY / TOO / LS" in a narrow Tool Library
                // (L-61, L-89, live test 8).
                Text(title)
                    .zpdfText(.sectionHeader, .textPrimary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .zpdfText(.caption, .textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // IM-058: the whole title band toggles a disclosure header, not only the 24 pt
            // chevron; VoiceOver keeps the one button (the chevron) with its expanded value.
            .frame(maxWidth: isExpanded == nil ? nil : .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded?.wrappedValue.toggle() }
            if let count {
                Text(count.formatted())
                    .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                    .padding(.horizontal, ZPDFSpacing.xs)
                    .padding(.vertical, 1)
                    .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.hairline)
                    // Never broken across lines: "14" wrapped to "1 / 4" (L-61).
                    .fixedSize()
                    // BH-503: "1 items".
                    .accessibilityLabel(Text(Self.countAccessibilityLabel(count)))
            }
            Spacer(minLength: ZPDFSpacing.s)
            accessory
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(minHeight: ZPDFSpacing.Control.panelHeader)
        .background(ZPDFColor.color(isHovering ? .elevated : .surface))
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .overlay(alignment: .bottom) { ZPDFHairlineDivider(axis: .horizontal) }
        .accessibilityElement(children: .contain)
    }

    /// "1 item", "3 items" — the count badge's spoken label (BH-503).
    static func countAccessibilityLabel(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld items",
            count: count,
            one: NSLocalizedString("%lld item", comment: "Accessibility: one item in a panel header"),
            other: NSLocalizedString("%lld items", comment: "Accessibility: item count in a panel header")
        )
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if let isExpanded {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                ZPDFGlyphView(
                    .symbol(isExpanded.wrappedValue ? .disclosureOpen : .disclosureClosed),
                    size: ZPDFSpacing.Control.iconSmall
                )
                .foregroundStyle(ZPDFColor.textSecondary)
                .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isFocused)
            .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
            .accessibilityLabel(title)
            .accessibilityValue(
                isExpanded.wrappedValue
                    ? Text(NSLocalizedString("Expanded", comment: "Accessibility value: section is expanded"))
                    : Text(NSLocalizedString("Collapsed", comment: "Accessibility value: section is collapsed"))
            )
            .zpdfAnimation(.quick, value: isExpanded.wrappedValue)
        }
    }
}

public extension ZPDFPanelHeader where Accessory == EmptyView {
    /// A header with no trailing controls.
    init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        isExpanded: Binding<Bool>? = nil
    ) {
        self.init(title: title, subtitle: subtitle, count: count, isExpanded: isExpanded) { EmptyView() }
    }
}

#if DEBUG
struct ZPDFPanelHeader_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var expanded = true

        var body: some View {
            ZPDFPreviewPanel("Panel headers") {
                VStack(spacing: 0) {
                    ZPDFPanelHeader(
                        title: NSLocalizedString("Measurement", comment: "Preview label"),
                        subtitle: NSLocalizedString("1:50 · millimetres", comment: "Preview label"),
                        count: 12,
                        isExpanded: $expanded
                    ) {
                        ZPDFToolbarButton(glyph: .symbol(.add), title: NSLocalizedString("Add", comment: "Preview label")) {}
                    }
                    ZPDFPanelHeader(title: NSLocalizedString("Custom Data", comment: "Preview label"))
                }
                .zpdfControlBackground(fill: .surface, cornerRadius: ZPDFRadius.large)
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFPanelHeader - dark and light")
    }
}
#endif
