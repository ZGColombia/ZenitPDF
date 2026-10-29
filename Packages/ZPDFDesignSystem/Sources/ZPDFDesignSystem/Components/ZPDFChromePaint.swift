import SwiftUI

/// How a chrome control paints itself in one state: pure data, no view.
///
/// Every 2026-09-23 component resolves its look through `ZPDFControlPaints`, so a test can pin
/// "the active tool chip uses the accent fill" or "a selected tab carries the indicator bar"
/// without rendering pixels, and a restyle happens in one table instead of in nine views.
public struct ZPDFControlPaint: Sendable, Hashable {
    /// The ground under the content, or `nil` for a transparent control.
    public var fill: ZPDFColorToken?
    /// Glyph and label colour.
    public var foreground: ZPDFColorToken
    /// Multiplier on the foreground's own opacity; below 1 only for disabled controls.
    public var foregroundOpacity: Double
    /// Outline, or `nil` for none.
    public var stroke: ZPDFColorToken?
    /// Outline width in points; meaningful only with a `stroke`.
    public var strokeWidth: CGFloat
    /// The hover / pressed state layer composited over `fill`.
    public var overlay: ZPDFColorToken?
    /// The bar under a selected tab or toggled button, or `nil`.
    public var indicator: ZPDFColorToken?
    /// The type role for the label.
    public var textStyle: ZPDFTextStyle

    public init(
        fill: ZPDFColorToken? = nil,
        foreground: ZPDFColorToken,
        foregroundOpacity: Double = 1,
        stroke: ZPDFColorToken? = nil,
        strokeWidth: CGFloat = ZPDFStroke.regular,
        overlay: ZPDFColorToken? = nil,
        indicator: ZPDFColorToken? = nil,
        textStyle: ZPDFTextStyle = .control
    ) {
        self.fill = fill
        self.foreground = foreground
        self.foregroundOpacity = foregroundOpacity
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.overlay = overlay
        self.indicator = indicator
        self.textStyle = textStyle
    }
}

/// A control's paint in each interaction state.
public struct ZPDFControlPaintSet: Sendable, Hashable {
    public var rest: ZPDFControlPaint
    public var hover: ZPDFControlPaint
    public var pressed: ZPDFControlPaint

    public init(rest: ZPDFControlPaint, hover: ZPDFControlPaint, pressed: ZPDFControlPaint) {
        self.rest = rest
        self.hover = hover
        self.pressed = pressed
    }

    /// Builds the set from one resolver.
    public init(_ resolve: (ZPDFInteractionState) -> ZPDFControlPaint) {
        self.init(rest: resolve(.rest), hover: resolve(.hover), pressed: resolve(.pressed))
    }

    public func paint(for state: ZPDFInteractionState) -> ZPDFControlPaint {
        switch state {
        case .rest: return rest
        case .hover: return hover
        case .pressed: return pressed
        }
    }
}

/// The paint table for every 2026-09-23 chrome component.
///
/// State lines — a selected card's border, a toggled button's edge, the indicator bar — are
/// always `accentBlue`, never `accent`: the accessibility plan asks 3:1 for a state boundary,
/// and the `accent` fill blue is under 3:1 against the dark panels. `accent` is a fill only.
public enum ZPDFControlPaints {

    /// Foreground opacity of a disabled control. Disabled text is exempt from WCAG contrast,
    /// and the shape stays visible so the layout does not jump.
    public static let disabledOpacity: Double = 0.55

    /// One segment of a segmented tab control. Selected: `selectedFill`, primary text, semibold,
    /// and the `accentBlue` indicator bar — fill, weight and bar together, never colour alone.
    public static func tab(
        isSelected: Bool,
        state: ZPDFInteractionState,
        isEnabled: Bool,
        compact: Bool = false
    ) -> ZPDFControlPaint {
        let restStyle: ZPDFTextStyle = compact ? .control : .tab
        let selectedStyle: ZPDFTextStyle = compact ? .control.withWeight(.semibold) : .tabSelected
        if isSelected {
            return ZPDFControlPaint(
                fill: .selectedFill,
                foreground: .textPrimary,
                foregroundOpacity: isEnabled ? 1 : disabledOpacity,
                overlay: isEnabled ? state.overlay : nil,
                indicator: .accentBlue,
                textStyle: selectedStyle
            )
        }
        return ZPDFControlPaint(
            foreground: .textSecondary,
            foregroundOpacity: isEnabled ? 1 : disabledOpacity,
            overlay: isEnabled ? state.overlay : nil,
            textStyle: restStyle
        )
    }

    /// The track a segmented control's segments sit in.
    public static func tabTrack(compact: Bool) -> ZPDFControlPaint {
        ZPDFControlPaint(fill: compact ? .surface : .elevated, foreground: .textSecondary, stroke: .border)
    }

    /// The compact icon / icon-and-title toolbar button (canvas bar, ledger bar).
    ///
    /// Selected (a toggle that is on, "Per Sheet"): `selectedFill`, an `accentBlue` outline and the
    /// indicator bar. Prominence tints the foreground of an unselected button only.
    public static func toolbarButton(
        isSelected: Bool,
        prominence: ZPDFToolbarButton.Prominence,
        state: ZPDFInteractionState,
        isEnabled: Bool
    ) -> ZPDFControlPaint {
        let tint: ZPDFColorToken
        switch prominence {
        case .standard: tint = .textPrimary
        case .accent: tint = .accentBlue
        case .destructive: tint = .danger
        }
        guard isEnabled else {
            return ZPDFControlPaint(
                fill: isSelected ? .selectedFill : nil,
                foreground: isSelected ? .textPrimary : tint,
                foregroundOpacity: disabledOpacity,
                stroke: isSelected ? .accentBlue : nil,
                indicator: isSelected ? .accentBlue : nil
            )
        }
        if isSelected {
            return ZPDFControlPaint(
                fill: .selectedFill,
                foreground: .textPrimary,
                stroke: .accentBlue,
                overlay: state.overlay,
                indicator: .accentBlue,
                textStyle: .control.withWeight(.medium)
            )
        }
        return ZPDFControlPaint(foreground: tint, overlay: state.overlay)
    }

    /// A text field, the rounded search field and a popup row: recessed `inset` ground with a
    /// `borderStrong` edge that turns `accentBlue` while the field has keyboard focus.
    public static func field(isFocused: Bool, state: ZPDFInteractionState, isEnabled: Bool) -> ZPDFControlPaint {
        ZPDFControlPaint(
            fill: .inset,
            foreground: .textPrimary,
            foregroundOpacity: isEnabled ? 1 : disabledOpacity,
            stroke: isFocused ? .accentBlue : .borderStrong,
            overlay: isEnabled && !isFocused ? state.overlay : nil,
            textStyle: .control
        )
    }

    /// A summary chip in the ledger bar. Selected chips (an active kind filter) take the
    /// `selectedFill` with an `accentBlue` outline; the rest sit transparent on the band.
    public static func summaryChip(isSelected: Bool, state: ZPDFInteractionState, isInteractive: Bool) -> ZPDFControlPaint {
        let overlay = isInteractive ? state.overlay : nil
        if isSelected {
            return ZPDFControlPaint(fill: .selectedFill, foreground: .textPrimary, stroke: .accentBlue, overlay: overlay)
        }
        return ZPDFControlPaint(foreground: .textPrimary, overlay: overlay)
    }
}

// MARK: - Drawing

/// Paints a `ZPDFControlPaint` ground: fill, then state layer, then outline.
public struct ZPDFPaintedBackground: View {
    private let paint: ZPDFControlPaint
    private let cornerRadius: CGFloat

    public init(_ paint: ZPDFControlPaint, cornerRadius: CGFloat = ZPDFRadius.control) {
        self.paint = paint
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let fill = paint.fill {
                shape.fill(ZPDFColor.color(fill))
            }
            if let overlay = paint.overlay {
                shape.fill(ZPDFColor.color(overlay))
            }
            if let stroke = paint.stroke {
                shape.strokeBorder(ZPDFColor.color(stroke), lineWidth: paint.strokeWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A button style that resolves hover and press into a `ZPDFControlPaintSet` and paints it.
///
/// The label receives the foreground colour; the ground is drawn behind it.
public struct ZPDFPaintedButtonStyle: ButtonStyle {
    private let paints: ZPDFControlPaintSet
    private let cornerRadius: CGFloat
    private let isHovering: Bool
    private let isEnabled: Bool

    public init(_ paints: ZPDFControlPaintSet, cornerRadius: CGFloat = ZPDFRadius.control, isHovering: Bool, isEnabled: Bool = true) {
        self.paints = paints
        self.cornerRadius = cornerRadius
        self.isHovering = isHovering
        self.isEnabled = isEnabled
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = ZPDFInteractionState.resolve(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
        let paint = paints.paint(for: state)
        return configuration.label
            .foregroundStyle(ZPDFColor.color(paint.foreground).opacity(paint.foregroundOpacity))
            .background { ZPDFPaintedBackground(paint, cornerRadius: cornerRadius) }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The indicator bar under a selected tab or toggled button.
struct ZPDFIndicatorBar: View {
    let token: ZPDFColorToken?
    let inset: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: ZPDFSpacing.Chrome.tabIndicatorHeight / 2, style: .continuous)
            .fill(ZPDFColor.color(token ?? .accentBlue))
            .frame(height: ZPDFSpacing.Chrome.tabIndicatorHeight)
            .padding(.horizontal, inset)
            .opacity(token == nil ? 0 : 1)
            .allowsHitTesting(false)
    }
}
