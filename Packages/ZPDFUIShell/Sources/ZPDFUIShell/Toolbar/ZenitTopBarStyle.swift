import SwiftUI
import ZPDFDesignSystem

/// The top bar's look, in one place: which design-system token each part of the bar reads,
/// and the metrics the 2026-09-23 main-window mockup gives the brand, the tool chips, the
/// workspace group and the author badge.
///
/// Every colour is a ``ZPDFColorToken``, so both appearances (and Increase Contrast) come
/// from the design system. Nothing in the toolbar spells a colour literal.
enum ZenitTopBarStyle {

    // MARK: - Tokens

    /// The filled rounded rectangle behind the armed tool.
    static let armedFill: ZPDFColorToken = .accent
    /// Glyph and caption on the armed fill.
    static let onArmedFill: ZPDFColorToken = .textOnAccent
    /// Glyph and caption of a chip at rest.
    static let chipForeground: ZPDFColorToken = .textPrimary
    /// The translucent hover overlay of a chip that is not armed.
    static let hoverFill: ZPDFColorToken = .stateHover
    /// The translucent pressed overlay of a chip that is not armed.
    static let pressedFill: ZPDFColorToken = .statePressed
    /// Glyph and label of a workspace chip whose panel is open (the mockup's blue Tool Library).
    static let openGlyph: ZPDFColorToken = .accentBlue
    /// The faint fill under a workspace chip whose panel is open.
    static let openFill: ZPDFColorToken = .selectedFill
    /// The rounded workspace group's fill.
    static let groupFill: ZPDFColorToken = .surface
    /// The rounded workspace group's 1 px outline, and the tool-group separator.
    static let hairline: ZPDFColorToken = .border
    /// The brand wordmark.
    static let wordmark: ZPDFColorToken = .textPrimary
    /// The letter-spaced tagline under the wordmark's baseline.
    static let tagline: ZPDFColorToken = .textTertiary
    /// The brand mark.
    static let mark: ZPDFColorToken = .accent
    /// The author badge's disc.
    static let badgeFill: ZPDFColorToken = .accent
    /// The author badge's initials.
    static let badgeForeground: ZPDFColorToken = .textOnAccent
    /// The author badge's thin outer ring.
    static let badgeRing: ZPDFColorToken = .borderStrong

    // MARK: - Metrics (points, estimated from the 1672 pt wide mockup)

    /// A tool chip's height (the mockup's Select fill).
    static let chipHeight: CGFloat = ZPDFSpacing.Chrome.toolButtonHeight
    /// The narrowest a chip gets, so Pan and Text do not shrink to their caption.
    static let chipMinWidth: CGFloat = ZPDFSpacing.Chrome.toolButtonWidth
    /// Horizontal padding inside a chip.
    static let chipHorizontalPadding: CGFloat = 10
    /// Corner radius of the armed fill and of the hover fill.
    static let chipCornerRadius: CGFloat = ZPDFRadius.card
    /// Glyph size in a chip.
    static let chipIcon: CGFloat = ZPDFSpacing.Chrome.toolIcon
    /// Point size an SF Symbol glyph is set at inside the 20 pt icon box, so its optical height
    /// matches the mockup's ~18 pt glyphs.
    static let chipSymbolPointSize: CGFloat = ZPDFSpacing.Chrome.toolIcon * 0.95
    /// Box a Zenit measurement glyph is drawn in: its artwork has a margin inside the box, so a
    /// slightly larger box lands on the same optical size as the symbols.
    static let chipMeasurementIcon: CGFloat = ZPDFSpacing.Chrome.toolIcon + 2
    /// The palette indicator in a chip's lower-right corner (Measure, Count).
    static let cornerIndicatorSize: CGFloat = 6
    /// The corner indicator's hit area.
    static let cornerIndicatorHitSize: CGFloat = 16
    /// The corner indicator's inset from the chip's edges.
    static let cornerIndicatorInset: CGFloat = 3
    /// The separate › disclosure after the Shapes chip.
    static let separateIndicatorSize: CGFloat = 10
    /// Gap between glyph and caption.
    static let chipLabelGap: CGFloat = ZPDFSpacing.Chrome.toolIconLabelGap
    /// Corner radius of the rounded workspace group.
    static let groupCornerRadius: CGFloat = ZPDFRadius.panel
    /// Inset between the workspace group's outline and its chips.
    static let groupInset: CGFloat = 4
    /// The author badge's diameter.
    static let badgeDiameter: CGFloat = ZPDFSpacing.Chrome.avatarLarge
    /// The tool-group separator's height.
    static let separatorHeight: CGFloat = 32
    /// Width reserved around the separator hairline.
    static let separatorWidth: CGFloat = 13

    // MARK: - Chip appearance

    /// What a chip looks like, resolved from its state. A value, so tests can pin the
    /// state-to-token table without rendering anything.
    struct ChipAppearance: Equatable {
        /// The rounded fill, or `nil` for none.
        var fill: ZPDFColorToken?
        /// Opacity applied to ``fill``.
        var fillOpacity: Double
        /// The glyph's colour.
        var glyph: ZPDFColorToken
        /// The caption's colour.
        var caption: ZPDFColorToken
        /// Opacity applied to glyph and caption.
        var foregroundOpacity: Double
        /// Whether the caption takes the heavier tool-label weight (a shape change, so the armed state survives
        /// greyscale and colour blindness, not only a colour change).
        var isEmphasised: Bool
    }

    /// The chip's state, as the view knows it.
    struct ChipState: Equatable {
        /// This chip is the armed tool.
        var isArmed = false
        /// This chip toggles a panel that is open.
        var isOpen = false
        var isHovering = false
        var isPressed = false
        var isEnabled = true
    }

    /// The one state-to-appearance table.
    ///
    /// - Armed: the accent fill with light glyph and caption, semibold — the mockup's Select.
    /// - Open panel: glyph and label in `accentBlue` on a faint fill, plus the selected
    ///   accessibility trait, so an open Tool Library reads as open
    ///   without competing with the armed tool for the one strong accent in the bar.
    /// - Hover and pressed: the design system's translucent hover and pressed overlays.
    /// - Disabled: no fill, half-strength secondary text.
    static func appearance(_ state: ChipState) -> ChipAppearance {
        guard state.isEnabled else {
            return ChipAppearance(
                fill: nil, fillOpacity: 0,
                glyph: .textSecondary, caption: .textSecondary,
                foregroundOpacity: 0.5, isEmphasised: false
            )
        }
        if state.isArmed {
            return ChipAppearance(
                fill: armedFill, fillOpacity: state.isPressed ? 0.85 : 1,
                glyph: onArmedFill, caption: onArmedFill,
                foregroundOpacity: 1, isEmphasised: true
            )
        }
        if state.isOpen {
            return ChipAppearance(
                fill: openFill, fillOpacity: state.isPressed ? 1 : (state.isHovering ? 0.9 : 0.75),
                glyph: openGlyph, caption: openGlyph,
                foregroundOpacity: 1, isEmphasised: true
            )
        }
        if state.isPressed {
            return ChipAppearance(
                fill: pressedFill, fillOpacity: 1,
                glyph: chipForeground, caption: chipForeground,
                foregroundOpacity: 1, isEmphasised: false
            )
        }
        if state.isHovering {
            return ChipAppearance(
                fill: hoverFill, fillOpacity: 1,
                glyph: chipForeground, caption: chipForeground,
                foregroundOpacity: 1, isEmphasised: false
            )
        }
        return ChipAppearance(
            fill: nil, fillOpacity: 0,
            glyph: chipForeground, caption: chipForeground,
            foregroundOpacity: 0.92, isEmphasised: false
        )
    }
}
