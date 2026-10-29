import SwiftUI

/// The edge a pane lives on, and therefore where its ear sits when the pane is closed.
public enum ZPDFPaneEdge: String, CaseIterable, Hashable, Sendable, Identifiable {

    /// The left edge in a left-to-right layout.
    case leading
    /// The right edge in a left-to-right layout.
    case trailing
    /// The bottom edge.
    case bottom

    /// Stable identity.
    public var id: String { rawValue }

    /// The chevron an ear on this edge draws: it points the way the pane will travel when it
    /// comes back, so the glyph is a prediction of the motion rather than a decoration.
    public var chevron: ZPDFSymbol {
        switch self {
        case .leading: return .chevronTrailing
        case .trailing: return .chevronLeading
        case .bottom: return .chevronUp
        }
    }

    /// Whether ears on this edge are stacked along a horizontal run.
    public var isHorizontalRun: Bool { self == .bottom }
}

/// The tab left behind when a pane is closed, and the only affordance that says the pane is
/// still there: a small "ear" on the edge the pane occupied, which a click turns back into the pane.
///
/// The rule the ear exists to keep: **a control that hides something must be the control that
/// shows it, or a visible affordance must remain where the thing was.** A `✕` that removes a
/// pane and a menu item three levels away that restores it are not a pair.
///
/// Three decisions in the drawing:
///
/// - **Quiet by default.** The border tone and the secondary text colour, no accent. An ear
///   that shouts is worse than no ear, because it competes with the drawing for the whole
///   session in exchange for a click somebody makes twice a day.
/// - **Contrast on hover**, not colour: the ground goes to `elevated`, the chevron to
///   `textPrimary`, and the border reaches full strength. Nothing about the state is carried
///   by hue alone.
/// - **A real control.** It is a `Button`, it takes keyboard focus and draws the Zenit focus
///   ring, and its accessibility label is the sentence a screen-reader user needs — *"Show
///   Quantity Ledger"* — not the word "ear".
public struct ZPDFPaneEar: View {

    /// The ear's thickness across the edge it sits on.
    public static let thickness: CGFloat = 12
    /// The ear's length along the edge it sits on. Comfortably over the 24 pt hit target on
    /// the axis the pointer has to find, while staying a hairline detail on the other.
    public static let length: CGFloat = 56

    private let edge: ZPDFPaneEdge
    private let paneName: String
    private let accessibilityTitle: String
    private let keyboardHint: String?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - edge: which edge the closed pane lived on.
    ///   - paneName: the pane's name, shown as hover help.
    ///   - accessibilityTitle: what VoiceOver says — the full *"Show Quantity Ledger"* form.
    ///   - keyboardHint: the menu shortcut that does the same thing, spoken after the label.
    ///   - action: restores the pane, at the size it had.
    public init(
        edge: ZPDFPaneEdge,
        paneName: String,
        accessibilityTitle: String,
        keyboardHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.edge = edge
        self.paneName = paneName
        self.accessibilityTitle = accessibilityTitle
        self.keyboardHint = keyboardHint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZPDFGlyphView(.symbol(edge.chevron), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(chevronColor)
                .frame(width: width, height: height)
                .background(shape.fill(ground))
                .overlay(shape.strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .help(helpTag)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(Text(ZPDFToolbarButton.spokenHint(display: keyboardHint, spoken: nil)))
        .accessibilityAddTraits(.isButton)
    }

    private var helpTag: String {
        guard let keyboardHint, !keyboardHint.isEmpty else { return paneName }
        return "\(paneName) (\(keyboardHint))"
    }

    private var width: CGFloat { edge.isHorizontalRun ? Self.length : Self.thickness }

    private var height: CGFloat { edge.isHorizontalRun ? Self.thickness : Self.length }

    /// The four corner radii for an ear on `edge`: the two corners against the window edge
    /// are square.
    static func cornerRadii(
        for edge: ZPDFPaneEdge, radius r: CGFloat
    ) -> (topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) {
        switch edge {
        case .leading: return (0, 0, r, r)
        case .trailing: return (r, r, 0, 0)
        case .bottom: return (r, 0, 0, r)
        }
    }

    /// Only the corners that face into the window are rounded; the two against the window
    /// edge stay square, so the ear reads as attached rather than as a floating pill.
    private var shape: UnevenRoundedRectangle {
        let r = ZPDFRadius.small
        switch edge {
        case .leading:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: r,
                topTrailingRadius: r,
                style: .continuous
            )
        case .trailing:
            // BH-502: against the window's right edge, so the leading corners round and the
            // trailing ones stay square — this was a copy of the bottom case.
            let radii = Self.cornerRadii(for: .trailing, radius: r)
            return UnevenRoundedRectangle(
                topLeadingRadius: radii.topLeading,
                bottomLeadingRadius: radii.bottomLeading,
                bottomTrailingRadius: radii.bottomTrailing,
                topTrailingRadius: radii.topTrailing,
                style: .continuous
            )
        case .bottom:
            return UnevenRoundedRectangle(
                topLeadingRadius: r,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: r,
                style: .continuous
            )
        }
    }

    private var ground: Color {
        isHovering && isEnabled ? ZPDFColor.elevated : ZPDFColor.surface
    }

    private var chevronColor: Color {
        if !isEnabled { return ZPDFColor.textSecondary.opacity(0.5) }
        return isHovering ? ZPDFColor.textPrimary : ZPDFColor.textSecondary
    }
}

#if DEBUG
struct ZPDFPaneEar_Previews: PreviewProvider {
    static var previews: some View {
        ZPDFAppearancePair {
            ZPDFPreviewPanel("Pane ears") {
                HStack(spacing: ZPDFSpacing.xxl) {
                    ForEach(ZPDFPaneEdge.allCases) { edge in
                        ZPDFPaneEar(
                            edge: edge,
                            paneName: "Quantity Ledger",
                            accessibilityTitle: "Show Quantity Ledger",
                            keyboardHint: "Option Command L"
                        ) {}
                    }
                }
            }
        }
        .previewDisplayName("ZPDFPaneEar - dark and light")
    }
}
#endif
