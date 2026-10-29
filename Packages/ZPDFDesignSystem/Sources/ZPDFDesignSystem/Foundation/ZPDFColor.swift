import AppKit
import SwiftUI

/// Semantic colour tokens for the Zenit design system.
///
/// Views never reference raw hex. They reference a token; the token resolves itself for
/// light / dark and for the Increase Contrast accessibility appearances.
///
/// Since the 2026-09-23 main-window mockup the dark appearance is one continuous navy surface
/// family: `background` (window chrome and gutters) < `inset` (fields) < `surface` (panels) <
/// `elevated` (raised cards, the tab track) with white hairlines at 10 % between them. Only the
/// PDF page is light, which is why the markup inks (`inkBlue`, `inkRed`, `inkGreen`,
/// `pillFill`) keep one value across light and dark: they are always drawn on paper.
public enum ZPDFColorToken: String, CaseIterable, Sendable, Hashable {
    /// Window chrome: the top bar, the tab strip and the gutters between panels.
    case background
    /// Panels, inspectors, popovers, the canvas bar and the ledger band.
    case surface
    /// Raised chrome: the selected page card, the open document tab, segmented tracks, sheets.
    case elevated
    /// Hairline separators and quiet control outlines.
    case border
    /// Primary reading text.
    case textPrimary
    /// Labels, units, secondary metadata.
    case textSecondary
    /// Primary Zenit accent: measurement affordances.
    case accentCyan
    /// Accent used as a foreground on chrome: links, indicators, the focus ring, accent icons.
    case accentBlue
    /// Confirmed, validated, calibrated.
    case success
    /// Needs attention but is not blocking.
    case warning
    /// Blocking error or destructive action.
    case danger
    /// Selection fill on canvas and in lists.
    case selection
    /// The area behind a PDF page inside the canvas viewport.
    case canvasBackdrop
    /// Stroke colour for measurement geometry drawn over a page.
    case measurementInk
    /// Highlight ring shown when a snap candidate is acquired.
    case snapHighlight

    // MARK: 2026-09-23 mockup tokens

    /// Recessed ground of text fields, the document search field and multi-line notes.
    case inset
    /// Emphasised outline: text fields, popup rows, panel edges, the selected card's resting edge.
    case borderStrong
    /// Placeholders, the brand tagline, counts and other third-level text.
    case textTertiary
    /// Text and glyphs drawn on an `accent` fill (the active tool, the avatar, primary buttons).
    case textOnAccent
    /// The filled accent: the active tool chip, primary buttons, avatars. A fill only — borders,
    /// edges and indicator bars use `accentBlue`, because this blue is under 3:1 against the dark
    /// panels.
    case accent
    /// Selected segment of a segmented tab control and a toggled toolbar button ("Per Sheet").
    case selectedFill
    /// Translucent overlay composited over any fill while the pointer hovers it.
    case stateHover
    /// Translucent overlay composited over any fill while it is pressed.
    case statePressed
    /// Fill of a measurement label pill drawn on the page ("Area: 620 SF").
    case pillFill
    /// Default blue markup ink on the page: area strokes, lengths, blue callouts.
    case inkBlue
    /// Red markup ink on the page: red callouts and revision clouds.
    case inkRed
    /// Green markup ink on the page: green callouts and revision clouds.
    case inkGreen
    /// Page white: the sheet a PDF page, a thumbnail placeholder or a paper preview is drawn
    /// on. The one token that is identical in every appearance — paper does not change colour
    /// with the system theme (see `appearanceInvariant`).
    case paper
    /// Ground of the bottom Quantity Ledger bar: one step lighter than the panels, as the
    /// mockup draws it (#151F32 against #0E1927).
    case ledgerBar

    /// Tokens deliberately identical in all four appearance variants, and therefore exempt from
    /// the rule that every Increase Contrast variant differs from its normal value. The
    /// self-check holds them to the opposite rule: all four values must be equal.
    public static let appearanceInvariant: Set<ZPDFColorToken> = [.paper]
}

/// One token's value across all four appearance variants.
public struct ZPDFColorSet: Sendable, Hashable {
    public let light: ZPDFRGBA
    public let dark: ZPDFRGBA
    public let lightHighContrast: ZPDFRGBA
    public let darkHighContrast: ZPDFRGBA

    public init(light: ZPDFRGBA, dark: ZPDFRGBA, lightHighContrast: ZPDFRGBA, darkHighContrast: ZPDFRGBA) {
        self.light = light
        self.dark = dark
        self.lightHighContrast = lightHighContrast
        self.darkHighContrast = darkHighContrast
    }

    public func value(for variant: ZPDFAppearanceVariant) -> ZPDFRGBA {
        switch variant {
        case .light: return light
        case .dark: return dark
        case .lightHighContrast: return lightHighContrast
        case .darkHighContrast: return darkHighContrast
        }
    }
}

/// Resolves semantic tokens into AppKit and SwiftUI colours.
///
/// Every accessor returns a *dynamic* colour built with `NSColor(name:dynamicProvider:)`, so a
/// view drawn once keeps working when the user flips to dark mode or turns on Increase Contrast.
public enum ZPDFColor {

    // MARK: - Palette

    /// The single source of truth for the Zenit palette.
    ///
    /// Values marked "mockup" were sampled from the 2026-09-23 main-window design mockup (a
    /// reference image that is not distributed with the source) as raw sRGB bytes (CGImage data provider, no colour matching; median of a clean patch;
    /// text from the stroke core of the glyphs). A first pass read the pixels through AppKit's
    /// display-profile conversion, which lifted every dark tone 5-15 levels toward blue; the
    /// polish round (d9 QA) re-sampled the chrome from raw bytes. Where a raw value would break
    /// a self-check contrast rule, the nearest compliant value is used and the comment says so. Values marked "spec"
    /// are the earlier design-system hex, kept where the mockup does not speak (the light
    /// appearance, status colours). Values marked "derived" fill in tones neither source gives —
    /// every Increase Contrast variant and the light counterparts of the mockup tokens — and are
    /// chosen to keep text and stroke contrast at or above WCAG AA against their own ground.
    public static func set(for token: ZPDFColorToken) -> ZPDFColorSet {
        switch token {
        case .background:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xF3F5F7),              // spec
                dark: ZPDFRGBA(hex: 0x081324),               // mockup raw: top bar (5,5), gutters #091320
                // CR-195: this was #FFFFFF, the same value as `surface`, so in Increase
                // Contrast the canvas backdrop and the panels standing on it were one flat
                // field — the one appearance where the edge between them matters most. A
                // slightly cooler grey keeps black text at 18.4:1 and the border hairline at
                // 3.96:1 while making the two grounds tell apart.
                lightHighContrast: ZPDFRGBA(hex: 0xEDF0F3),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x030C18)    // derived
            )
        case .surface:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xFFFFFF),              // spec
                // Raw panels are #0D1826 (navigator) / #0E1927 (inspector). #0E1927 keeps the
                // background/surface step at 1.051:1, just over the self-check's 1.05:1 floor.
                dark: ZPDFRGBA(hex: 0x0E1927),               // mockup raw: inspector (1500,845)
                lightHighContrast: ZPDFRGBA(hex: 0xFFFFFF),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0A1628)    // derived
            )
        case .elevated:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xE9EEF2),              // spec
                dark: ZPDFRGBA(hex: 0x16263F),               // mockup raw: selected card #15253F, tab #182843
                lightHighContrast: ZPDFRGBA(hex: 0xDDE4EA),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x172A47)    // derived
            )
        case .border:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xD3DCE3),                            // spec
                dark: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.10),                // spec, confirmed by mockup row dividers
                lightHighContrast: ZPDFRGBA(hex: 0x6B7883),                // derived
                // CR-194: 0.28 white composites to #4B4C4F..#5B6067 over the dark
                // high-contrast grounds, which is 2.36:1 to 2.52:1 — under the 3:1 WCAG 1.4.11
                // asks of a control boundary. 0.36 lands at 3.22:1 / 3.32:1 / 3.29:1 over
                // background, surface and elevated and stays a hairline rather than a rule.
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.36)     // derived
            )
        case .textPrimary:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x11171D),              // spec
                dark: ZPDFRGBA(hex: 0xF3F6FA),               // mockup
                lightHighContrast: ZPDFRGBA(hex: 0x000000),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF)    // derived
            )
        case .textSecondary:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x5E6B77),              // spec
                dark: ZPDFRGBA(hex: 0xB8C3D1),               // mockup: inspector row labels
                lightHighContrast: ZPDFRGBA(hex: 0x3A454F),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xD5DEE8)    // derived
            )
        case .accentCyan:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x087D84),              // spec
                dark: ZPDFRGBA(hex: 0x50D6DE),               // spec
                lightHighContrast: ZPDFRGBA(hex: 0x045C61),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x7FF0F6)    // derived
            )
        case .accentBlue:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x245FAF),              // spec
                // Sampled #3F94F5 from the mockup's selected-tab underline; raised to #5AA4F7 in
                // the d10 accessibility pass because the underline sits on `selectedFill`, where
                // #3F94F5 is 2.77:1 and #5AA4F7 is 3.31:1 (6.03:1 on `surface`).
                dark: ZPDFRGBA(hex: 0x5AA4F7),               // mockup-derived, raised for 3:1
                lightHighContrast: ZPDFRGBA(hex: 0x123F7D),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x8FC1FF)    // derived
            )
        case .success:
            return ZPDFColorSet(
                // Was #1F8F5F, 4.08:1 on white and 3.73:1 on `background` — under AA for the
                // success text it colours (4.5:1 for normal text, `ACCESSIBILITY_PLAN.md`).
                // #187A50 is 5.33:1 / 4.88:1.
                light: ZPDFRGBA(hex: 0x187A50),              // derived from zenit-green
                dark: ZPDFRGBA(hex: 0x4FD095),               // spec
                lightHighContrast: ZPDFRGBA(hex: 0x0F6B44),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x74E7B0)    // derived
            )
        case .warning:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x9A6B10),              // derived from warning
                dark: ZPDFRGBA(hex: 0xEFB957),               // spec
                lightHighContrast: ZPDFRGBA(hex: 0x6B4700),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFD37A)    // derived
            )
        case .danger:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xC0243A),              // derived from danger
                dark: ZPDFRGBA(hex: 0xF0616E),               // spec
                lightHighContrast: ZPDFRGBA(hex: 0x8E0F22),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFF8A93)    // derived
            )
        case .selection:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x2B6CB0),              // spec
                dark: ZPDFRGBA(hex: 0x0A5ECC),               // mockup: tracks the accent fill
                lightHighContrast: ZPDFRGBA(hex: 0x1B4C86),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x3D8BE6)    // derived
            )
        case .canvasBackdrop:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xDDE3E9),              // derived
                dark: ZPDFRGBA(hex: 0x0A1322),               // mockup raw: canvas edge (1366,500) #091222
                lightHighContrast: ZPDFRGBA(hex: 0xC9D2DA),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x000000)    // derived
            )
        case .measurementInk:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x087D84),              // tracks zenit-cyan
                dark: ZPDFRGBA(hex: 0x50D6DE),
                lightHighContrast: ZPDFRGBA(hex: 0x045C61),
                darkHighContrast: ZPDFRGBA(hex: 0x7FF0F6)
            )
        case .snapHighlight:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x1F8F5F),              // tracks zenit-green
                dark: ZPDFRGBA(hex: 0x4FD095),
                lightHighContrast: ZPDFRGBA(hex: 0x0F6B44),
                darkHighContrast: ZPDFRGBA(hex: 0x74E7B0)
            )

        // MARK: 2026-09-23 mockup tokens

        case .inset:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xF4F6F9),              // derived
                dark: ZPDFRGBA(hex: 0x0B1522),               // mockup raw: Notes #0B1421, Label #0E1726
                lightHighContrast: ZPDFRGBA(hex: 0xEBEFF3),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x06101D)    // derived
            )
        case .borderStrong:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xBCC7D1),                            // derived
                dark: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.16),                // mockup: panel and field edges
                lightHighContrast: ZPDFRGBA(hex: 0x56626D),                // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.46)     // derived
            )
        case .textTertiary:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x616D7A),              // derived
                dark: ZPDFRGBA(hex: 0x93A0B2),               // mockup: search placeholder, tagline
                lightHighContrast: ZPDFRGBA(hex: 0x434D58),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xB9C4D2)    // derived
            )
        case .textOnAccent:
            // Near-white in the normal appearances so each Increase Contrast variant can move to
            // pure white — the self-check requires a distinct value in every variant.
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xFBFCFF),              // mockup: "Select" label on the chip
                dark: ZPDFRGBA(hex: 0xF8FBFF),               // mockup
                lightHighContrast: ZPDFRGBA(hex: 0xFFFFFF),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF)    // derived
            )
        case .accent:
            return ZPDFColorSet(
                // Raw chip is #0854BE, which is 2.7:1 against the raw top bar — under the 3:1 the
                // self-check asks of the active chip's edge. #0A5ECC is the nearest value on the
                // same hue that clears 3:1 while white label text stays above 4.5:1.
                light: ZPDFRGBA(hex: 0x0A5ECC),              // mockup raw, nearest compliant
                dark: ZPDFRGBA(hex: 0x0A5ECC),               // mockup raw #0854BE, nearest compliant
                lightHighContrast: ZPDFRGBA(hex: 0x004A99),  // derived
                // White text needs the fill's luminance under 0.183 and the chip needs 3:1 against
                // the near-black high-contrast ground, which asks for at least 0.11; 0x0D6AD0
                // sits at 0.149 (5.3:1 for the label, 3.7:1 for the chip edge).
                darkHighContrast: ZPDFRGBA(hex: 0x0D6AD0)    // derived
            )
        case .selectedFill:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xD5E5F8),              // derived
                dark: ZPDFRGBA(hex: 0x123F78),               // mockup raw: tabs #12325C-#124287, Per Sheet #12427F
                lightHighContrast: ZPDFRGBA(hex: 0xB7D1F0),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0E3D6E)    // derived
            )
        case .stateHover:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x000000, alpha: 0.05),              // derived
                dark: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.06),               // derived
                lightHighContrast: ZPDFRGBA(hex: 0x000000, alpha: 0.09),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.10)    // derived
            )
        case .statePressed:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x000000, alpha: 0.10),              // derived
                dark: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.12),               // derived
                lightHighContrast: ZPDFRGBA(hex: 0x000000, alpha: 0.16),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.18)    // derived
            )
        case .pillFill:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x044EFC),              // mockup raw: pill #024DF9 / #0650FF (on paper)
                dark: ZPDFRGBA(hex: 0x044EFC),               // mockup raw
                lightHighContrast: ZPDFRGBA(hex: 0x0052C4),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0052C4)    // derived
            )
        case .inkBlue:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x1A55CF),              // mockup: area stroke, dashed length (on paper)
                dark: ZPDFRGBA(hex: 0x1A55CF),               // mockup
                lightHighContrast: ZPDFRGBA(hex: 0x0B3FA6),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0B3FA6)    // derived
            )
        case .inkRed:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xCB3022),              // mockup: red callout, red cloud (on paper)
                dark: ZPDFRGBA(hex: 0xCB3022),               // mockup
                lightHighContrast: ZPDFRGBA(hex: 0x9E1C12),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x9E1C12)    // derived
            )
        case .inkGreen:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0x1E7A4E),              // mockup: green callout, green cloud (on paper)
                dark: ZPDFRGBA(hex: 0x1E7A4E),               // mockup
                lightHighContrast: ZPDFRGBA(hex: 0x0F5C38),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0F5C38)    // derived
            )
        case .ledgerBar:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xEEF2F6),              // derived
                dark: ZPDFRGBA(hex: 0x141F32),               // mockup raw: bar (5,900) #151F32 / #121F31
                lightHighContrast: ZPDFRGBA(hex: 0xE3E8EE),  // derived
                darkHighContrast: ZPDFRGBA(hex: 0x0C1628)    // derived
            )
        case .paper:
            return ZPDFColorSet(
                light: ZPDFRGBA(hex: 0xFFFFFF),              // mockup: the page
                dark: ZPDFRGBA(hex: 0xFFFFFF),               // mockup: the page stays white on navy
                lightHighContrast: ZPDFRGBA(hex: 0xFFFFFF),  // invariant by design
                darkHighContrast: ZPDFRGBA(hex: 0xFFFFFF)    // invariant by design
            )
        }
    }

    // MARK: - Resolution

    /// The literal sRGB value of a token in a given appearance variant. Pure, no AppKit state.
    public static func rgba(_ token: ZPDFColorToken, _ variant: ZPDFAppearanceVariant) -> ZPDFRGBA {
        set(for: token).value(for: variant)
    }

    /// A dynamic `NSColor` that re-resolves itself whenever the drawing appearance changes,
    /// including switches into and out of Increase Contrast.
    public static func nsColor(_ token: ZPDFColorToken) -> NSColor {
        NSColor(name: NSColor.Name("zpdf.\(token.rawValue)")) { appearance in
            rgba(token, ZPDFAppearanceVariant.matching(appearance)).nsColor
        }
    }

    /// A dynamic `NSColor` at a fraction of the token's own opacity (a low-alpha area fill, a
    /// callout ground). Still re-resolves with the appearance, unlike
    /// `nsColor(token).withAlphaComponent(_:)` on an already-resolved colour.
    public static func nsColor(_ token: ZPDFColorToken, opacity: CGFloat) -> NSColor {
        let clamped = max(0, min(1, opacity))
        return NSColor(name: NSColor.Name("zpdf.\(token.rawValue).\(Int((clamped * 1000).rounded()))")) { appearance in
            let value = rgba(token, ZPDFAppearanceVariant.matching(appearance))
            return ZPDFRGBA(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha * clamped).nsColor
        }
    }

    /// A pinned `NSColor` for one variant. Used by snapshot rendering, PDF stamping and the
    /// self-check, where the drawing appearance cannot be relied on.
    public static func nsColor(_ token: ZPDFColorToken, variant: ZPDFAppearanceVariant) -> NSColor {
        rgba(token, variant).nsColor
    }

    /// A dynamic SwiftUI `Color` backed by the same provider.
    public static func color(_ token: ZPDFColorToken) -> Color {
        Color(nsColor: nsColor(token))
    }

    /// A dynamic SwiftUI `Color` at a fraction of the token's own opacity.
    public static func color(_ token: ZPDFColorToken, opacity: CGFloat) -> Color {
        Color(nsColor: nsColor(token, opacity: opacity))
    }

    /// An explicitly resolved SwiftUI colour, for the rare view that must pin a variant
    /// (snapshot rendering, PDF export previews, side-by-side appearance galleries).
    public static func color(_ token: ZPDFColorToken, variant: ZPDFAppearanceVariant) -> Color {
        rgba(token, variant).color
    }

    /// Explicit resolution from the SwiftUI environment pair.
    public static func color(
        _ token: ZPDFColorToken,
        scheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> Color {
        rgba(token, .matching(scheme: scheme, contrast: contrast)).color
    }

    // MARK: - Named conveniences

    public static var background: Color { color(.background) }
    public static var surface: Color { color(.surface) }
    public static var elevated: Color { color(.elevated) }
    public static var border: Color { color(.border) }
    public static var textPrimary: Color { color(.textPrimary) }
    public static var textSecondary: Color { color(.textSecondary) }
    public static var accentCyan: Color { color(.accentCyan) }
    public static var accentBlue: Color { color(.accentBlue) }
    public static var success: Color { color(.success) }
    public static var warning: Color { color(.warning) }
    public static var danger: Color { color(.danger) }
    public static var selection: Color { color(.selection) }
    public static var canvasBackdrop: Color { color(.canvasBackdrop) }
    public static var measurementInk: Color { color(.measurementInk) }
    public static var snapHighlight: Color { color(.snapHighlight) }
    public static var inset: Color { color(.inset) }
    public static var borderStrong: Color { color(.borderStrong) }
    public static var textTertiary: Color { color(.textTertiary) }
    public static var textOnAccent: Color { color(.textOnAccent) }
    public static var accent: Color { color(.accent) }
    public static var selectedFill: Color { color(.selectedFill) }
    public static var stateHover: Color { color(.stateHover) }
    public static var statePressed: Color { color(.statePressed) }
    public static var pillFill: Color { color(.pillFill) }
    public static var inkBlue: Color { color(.inkBlue) }
    public static var inkRed: Color { color(.inkRed) }
    public static var inkGreen: Color { color(.inkGreen) }
    public static var paper: Color { color(.paper) }
    public static var ledgerBar: Color { color(.ledgerBar) }
}

// MARK: - Interaction states

/// The interaction state of a control, resolved to one overlay token.
///
/// Hover and press are drawn as a translucent state layer over whatever fill the control has,
/// so an accent chip, a quiet toolbar button and a list row all react the same way and a
/// pressed accent chip never needs its own hand-picked darker blue.
public enum ZPDFInteractionState: Sendable, Hashable, CaseIterable {
    case rest
    case hover
    case pressed

    /// The overlay token for this state, or `nil` at rest.
    public var overlay: ZPDFColorToken? {
        switch self {
        case .rest: return nil
        case .hover: return .stateHover
        case .pressed: return .statePressed
        }
    }

    /// Resolves the state from the two flags a control tracks. Press wins over hover.
    public static func resolve(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> ZPDFInteractionState {
        guard isEnabled else { return .rest }
        if isPressed { return .pressed }
        if isHovering { return .hover }
        return .rest
    }
}
