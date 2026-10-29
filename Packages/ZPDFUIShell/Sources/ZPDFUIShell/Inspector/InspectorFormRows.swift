import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector's visual grammar, per the 2026-09-23 main-window mockup: a dark card per
/// group, labels in a quiet left column, boxed fields with a hairline edge, popups with a
/// trailing chevron, and a filled accent where something is selected.
///
/// Every colour is a design-system token; the names below say what each surface *is* in the
/// Inspector so the views read as the mockup does and a token rename is a one-line change.
enum InspectorChrome {

    /// The panel behind everything.
    static let panel: ZPDFColorToken = .surface
    /// A group card.
    static let card: ZPDFColorToken = .surface
    /// The header card: raised above the panel, the selected-card tone.
    static let raisedCard: ZPDFColorToken = .elevated
    /// The inside of a text field, popup or notes box: recessed below the card.
    static let field: ZPDFColorToken = .inset
    /// The resting edge of a field or popup.
    static let fieldEdge: ZPDFColorToken = .borderStrong
    /// Composited over a fill while the pointer is on it.
    static let hover: ZPDFColorToken = .stateHover
    /// Composited over a fill while it is pressed.
    static let pressed: ZPDFColorToken = .statePressed
    /// The selected tab's raised fill.
    static let selectedFill: ZPDFColorToken = .selectedFill
    /// Card edges and dividers.
    static let hairline: ZPDFColorToken = .border
    /// The filled accent: the header card's tile and the avatar disc.
    static let accentFill: ZPDFColorToken = .accent
    /// The accent as a line on chrome: the selected tab's indicator, a focused field's edge.
    static let accentLine: ZPDFColorToken = .accentBlue
    /// Text and glyphs drawn on the accent fill.
    static let onAccent: ZPDFColorToken = .textOnAccent
}

/// The Inspector's text roles. Values a person typed or picked read in regular weight, as the
/// mockup sets them; only the measured quantities are emphasised (d9 final QA).
enum InspectorTypography {
    /// Text inside a boxed field: Label, Notes.
    static let fieldValue: ZPDFTextStyle = .body
    /// The current value of a popup: Style, Status, Layer.
    static let popupValue: ZPDFTextStyle = .rowLabel
    /// The measured value in the display unit.
    static let emphasisedValue: ZPDFTextStyle = .valueEmphasis
}

/// Sizes the Inspector uses, from the design system's chrome metrics (measured on the
/// 2026-09-23 mockup, where one mockup pixel is about one point).
enum InspectorMetrics {
    /// The left label column of a Markup-tab row ("Fill Colour", "Border", "Modified"); wide
    /// enough for the UK "Fill Colour" at 13 pt, which the mockup's "Fill Color" was not.
    static let labelColumn: CGFloat = 70
    /// The wider label column of the Properties tab ("Scale Region", "Project Zone").
    static let propertiesLabelColumn: CGFloat = ZPDFSpacing.Control.inspectorLabelWidth
    /// A boxed field, popup or swatch row.
    static let fieldHeight: CGFloat = ZPDFSpacing.Chrome.fieldHeight
    /// A colour swatch.
    static let swatch: CGFloat = ZPDFSpacing.Chrome.swatch
    /// The author avatar.
    static let avatar: CGFloat = ZPDFSpacing.Chrome.avatarSmall
    /// The header card's accent tile.
    static let tile: CGFloat = ZPDFSpacing.Chrome.headerCardIcon
    /// The status dot.
    static let dot: CGFloat = ZPDFSpacing.Chrome.statusDot
    /// The tab strip.
    static let tabHeight: CGFloat = ZPDFSpacing.Chrome.segmentedTabHeight
    /// The selected tab's indicator.
    static let tabUnderline: CGFloat = ZPDFSpacing.Chrome.tabIndicatorHeight
    /// The panel title band ("INSPECTOR  ×").
    static let titleBand: CGFloat = 40
    /// Space between two rows inside a card.
    static let rowSpacing: CGFloat = ZPDFSpacing.m
    /// Padding inside a card.
    static let cardPadding: CGFloat = ZPDFSpacing.Chrome.panelPadding
    /// The gutter around the cards.
    static let gutter: CGFloat = ZPDFSpacing.Chrome.panelGutter
}

// MARK: - Cards

/// A rounded group with a hairline edge — the mockup's grouping for the header and the form.
struct InspectorCard<Content: View>: View {

    var padding: CGFloat = InspectorMetrics.cardPadding
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .fill(ZPDFColor.color(InspectorChrome.card))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                .strokeBorder(ZPDFColor.color(InspectorChrome.hairline), lineWidth: ZPDFStroke.regular)
        }
    }
}

// MARK: - Rows

/// Label on the left in a fixed column, control on the right: "Border  ■  2 pt".
struct InspectorInlineRow<Content: View>: View {

    let label: String
    var labelWidth: CGFloat = InspectorMetrics.labelColumn
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: ZPDFSpacing.m) {
            // Two lines before truncation, so a longer translation still reads whole.
            Text(label)
                .zpdfText(.rowLabel, .textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .leading)
                .help(label)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: InspectorMetrics.fieldHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// Label above, control below: "Label", "Notes".
struct InspectorStackedRow<Content: View>: View {

    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(label)
                .zpdfText(.rowLabel, .textSecondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// A measured quantity: the field name, the value in the display unit in strong numerals, and
/// the same value restated in the other unit system in secondary text.
struct InspectorQuantityRow: View {

    let label: String
    let primary: String
    let secondary: String?
    /// "×6" beside a repeated markup's one-instance value (W-040), `nil` otherwise: the ledger
    /// row multiplies the value, so the multiplier is never invisible here either.
    var repetition: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(label)
                .zpdfText(.rowLabel, .textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.m) {
                Text(primary)
                    .zpdfText(InspectorTypography.emphasisedValue, .textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
                if let repetition {
                    Text(repetition)
                        .zpdfText(.monoNumeric.withSize(13), .textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: ZPDFSpacing.m)
                if let secondary {
                    Text(secondary)
                        .zpdfText(.monoNumeric.withSize(13), .textSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // IM-025: the number is the value VoiceOver reads; "read-only" is the hint.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(Self.spokenValue(primary: primary, secondary: secondary, repetition: repetition)))
        .accessibilityHint(Text(InspectorPanel.readOnlyValueHint))
    }

    /// "620.0 ft², 57.6 m²" — both units, primary first; "12.00 m² ×6, 129.17 ft²" for a
    /// repeated markup, so VoiceOver hears the multiplier the row shows.
    static func spokenValue(primary: String, secondary: String?, repetition: String? = nil) -> String {
        let primary = repetition.map { "\(primary) \($0)" } ?? primary
        guard let secondary, !secondary.isEmpty else { return primary }
        return String(
            format: NSLocalizedString(
                "%1$@, %2$@",
                comment: "Inspector quantity spoken value: the value in the display unit, then in the other unit system"
            ),
            primary, secondary
        )
    }
}

// MARK: - Field chrome

/// The boxed look of a field or popup: a darker inset, a hairline edge that turns accent on
/// focus and lightens on hover.
struct InspectorFieldBox: ViewModifier {

    var isFocused: Bool = false
    var isHovering: Bool = false
    var isEnabled: Bool = true
    var minHeight: CGFloat = InspectorMetrics.fieldHeight
    /// Where the content sits when the box is taller than it: centred for a one-line field,
    /// top-leading for the multi-line notes box.
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        let state = ZPDFInteractionState.resolve(isHovering: isHovering, isPressed: false, isEnabled: isEnabled)
        content
            .padding(.horizontal, ZPDFSpacing.m)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                    .fill(ZPDFColor.color(InspectorChrome.field))
                    .overlay {
                        if let overlay = state.overlay {
                            RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                                .fill(ZPDFColor.color(overlay))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                    .strokeBorder(
                        ZPDFColor.color(isFocused ? InspectorChrome.accentLine : InspectorChrome.fieldEdge),
                        lineWidth: isFocused ? ZPDFStroke.emphasis : ZPDFStroke.regular
                    )
            }
            .opacity(isEnabled ? 1 : 0.55)
            .zpdfAnimation(.micro, value: isHovering)
            .zpdfAnimation(.micro, value: isFocused)
    }
}

extension View {
    /// Draws the Inspector's boxed field chrome around the view.
    func inspectorFieldBox(
        isFocused: Bool = false,
        isHovering: Bool = false,
        isEnabled: Bool = true,
        minHeight: CGFloat = InspectorMetrics.fieldHeight,
        alignment: Alignment = .leading
    ) -> some View {
        modifier(InspectorFieldBox(
            isFocused: isFocused, isHovering: isHovering, isEnabled: isEnabled,
            minHeight: minHeight, alignment: alignment
        ))
    }
}

/// A boxed popup: an optional tint dot, the current value, a trailing chevron, and a menu.
///
/// The menu is a borderless AppKit pull-down stretched across the box, with the box, dot and
/// chevron drawn around it. A macOS menu label only keeps text and images, so chrome drawn
/// *inside* the label would be dropped; drawn outside, it survives and the whole width stays
/// clickable.
struct InspectorPopup<MenuContent: View>: View {

    let title: String
    var dot: ZPDFColorToken? = nil
    var isEnabled: Bool = true
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        Menu {
            menu()
        } label: {
            Text(title)
                .zpdfText(InspectorTypography.popupValue, .textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, dot == nil ? 0 : InspectorMetrics.dot + ZPDFSpacing.m)
        .padding(.trailing, ZPDFSpacing.Control.iconSmall + ZPDFSpacing.xs)
        .overlay(alignment: .leading) {
            if let dot {
                Circle()
                    .fill(ZPDFColor.color(dot))
                    .frame(width: InspectorMetrics.dot, height: InspectorMetrics.dot)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) {
            ZPDFGlyphView(.symbol(.chevronDown), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.textSecondary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .inspectorFieldBox(isHovering: isHovering, isEnabled: isEnabled)
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
    }
}

/// A round avatar with the author's initials.
struct InspectorAvatar: View {

    let author: String
    /// The author's own colour (NL-COLLAB-05); `nil` keeps the shared accent. The initials are
    /// always drawn, so colour is never the only cue.
    var color: ColorRGBA? = nil

    var body: some View {
        if let color {
            Text(InspectorMarkupFormatting.initials(for: author))
                .font(ZPDFTypography.font(.avatarInitials.withSize(10)))
                .foregroundStyle(AuthorColors.initialsColor(on: color).swiftUIColor)
                .frame(width: InspectorMetrics.avatar, height: InspectorMetrics.avatar)
                .background(Circle().fill(color.swiftUIColor))
                .accessibilityHidden(true)
        } else {
            Text(InspectorMarkupFormatting.initials(for: author))
                .zpdfText(.avatarInitials.withSize(10), InspectorChrome.onAccent)
                .frame(width: InspectorMetrics.avatar, height: InspectorMetrics.avatar)
                .background(Circle().fill(ZPDFColor.color(InspectorChrome.accentFill)))
                .accessibilityHidden(true)
        }
    }
}

/// A thin horizontal rule between the quantity rows.
struct InspectorRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(ZPDFColor.color(InspectorChrome.hairline))
            .frame(height: ZPDFStroke.hairline)
            .accessibilityHidden(true)
    }
}
