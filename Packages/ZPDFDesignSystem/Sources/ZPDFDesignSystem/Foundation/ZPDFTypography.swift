import AppKit
import SwiftUI

/// A typographic role in the Graphite Workshop ramp.
///
/// The ramp is SF-based and deliberately compact: Zenit is a production tool where a
/// drawing sheet, an inspector and a ledger share one screen.
public struct ZPDFTextStyle: Hashable, Sendable {

    /// The face family a style is drawn with.
    public enum Face: String, Sendable, Hashable {
        /// SF Pro / system UI face.
        case system
        /// SF Pro with tabular figures — numeric columns must not shift width as digits change.
        case systemMonospacedDigits
        /// SF Mono — coordinates, raw values, identifiers.
        case monospaced
    }

    /// Point size at the system's default text size.
    public let baseSize: CGFloat
    /// `NSFont.Weight.rawValue`; stored as a plain `CGFloat` so the style stays `Sendable`.
    public let weightValue: CGFloat
    public let face: Face
    /// Extra tracking in points, applied on top of the system default.
    public let tracking: CGFloat

    public init(
        baseSize: CGFloat,
        weight: NSFont.Weight = .regular,
        face: Face = .system,
        tracking: CGFloat = 0
    ) {
        self.baseSize = baseSize
        self.weightValue = weight.rawValue
        self.face = face
        self.tracking = tracking
    }

    public var nsWeight: NSFont.Weight { NSFont.Weight(weightValue) }

    public var swiftUIWeight: Font.Weight {
        // BH-506: thresholds sit *between* AppKit's weights (ultraLight -0.8, thin -0.6,
        // light -0.4, regular 0), so each maps to its own SwiftUI weight. The old bounds put
        // thin (-0.6) under ultraLight and light (-0.4) under thin.
        switch weightValue {
        case ..<(-0.7): return .ultraLight
        case ..<(-0.5): return .thin
        case ..<(-0.2): return .light
        case ..<0.15: return .regular
        case ..<0.28: return .medium
        case ..<0.38: return .semibold
        case ..<0.52: return .bold
        case ..<0.6: return .heavy
        default: return .black
        }
    }

    /// A copy of this style at a different size, keeping face, weight and tracking.
    public func withSize(_ size: CGFloat) -> ZPDFTextStyle {
        ZPDFTextStyle(baseSize: size, weight: nsWeight, face: face, tracking: tracking)
    }

    /// A copy of this style at a different weight.
    public func withWeight(_ weight: NSFont.Weight) -> ZPDFTextStyle {
        ZPDFTextStyle(baseSize: baseSize, weight: weight, face: face, tracking: tracking)
    }
}

// MARK: - The ramp

public extension ZPDFTextStyle {

    /// Document/window title in the tab strip and title bar.
    static let windowTitle = ZPDFTextStyle(baseSize: 15, weight: .semibold, face: .system)

    /// Panel and inspector section headings ("Measurement", "Scale", "Custom Data").
    static let sectionHeader = ZPDFTextStyle(baseSize: 11, weight: .semibold, face: .system, tracking: 0.3)

    /// Default reading text in panels, sheets and help copy.
    static let body = ZPDFTextStyle(baseSize: 13, weight: .regular, face: .system)

    /// Text inside compact controls: toolbar labels, segmented controls, pickers, buttons.
    static let control = ZPDFTextStyle(baseSize: 12, weight: .regular, face: .system)

    /// Measurements, coordinates and every numeric column. Tabular figures are mandatory here:
    /// a quantity column that reflows as digits change is unreadable.
    static let monoNumeric = ZPDFTextStyle(baseSize: 12, weight: .regular, face: .systemMonospacedDigits)

    /// Emphasised numeric readout - ledger totals, the status bar's live measurement.
    static let monoNumericStrong = ZPDFTextStyle(baseSize: 12, weight: .semibold, face: .systemMonospacedDigits)

    /// Units, hints, timestamps, status bar metadata.
    static let caption = ZPDFTextStyle(baseSize: 11, weight: .regular, face: .system)

    /// Raw identifiers and code-like values (page labels, object IDs, file paths).
    static let code = ZPDFTextStyle(baseSize: 11, weight: .regular, face: .monospaced)

    // MARK: 2026-09-23 main-window mockup roles

    /// The brand wordmark in the top bar ("ZenitPDF").
    static let brandWordmark = ZPDFTextStyle(baseSize: 20, weight: .semibold, face: .system, tracking: -0.2)

    /// The letter-spaced brand tagline under or beside the wordmark. Callers upper-case the text.
    static let brandTagline = ZPDFTextStyle(baseSize: 10, weight: .medium, face: .system, tracking: 1.1)

    /// The label under an icon-over-label tool button ("Select", "Calibrate", "Tool Library").
    static let toolLabel = ZPDFTextStyle(baseSize: 12, weight: .regular, face: .system)

    /// The label of an active (selected) tool button: same size, one weight step up.
    static let toolLabelActive = ZPDFTextStyle(baseSize: 12, weight: .medium, face: .system)

    /// Letter-spaced panel title ("INSPECTOR"). Callers upper-case the text.
    static let panelTitle = ZPDFTextStyle(baseSize: 13, weight: .semibold, face: .system, tracking: 0.6)

    /// A segmented-tab label ("Pages", "Markup", "Quantities") at rest.
    static let tab = ZPDFTextStyle(baseSize: 12, weight: .regular, face: .system)

    /// The selected segmented-tab label.
    static let tabSelected = ZPDFTextStyle(baseSize: 12, weight: .semibold, face: .system)

    /// Title of a header card ("Area Measurement") and of a document tab.
    static let cardTitle = ZPDFTextStyle(baseSize: 14, weight: .semibold, face: .system)

    /// Row label in the inspector and field captions ("Label", "Area", "Fill Color").
    static let rowLabel = ZPDFTextStyle(baseSize: 13, weight: .regular, face: .system)

    /// The emphasised quantity in an inspector row ("620.0 SF", "100' - 0\""). Tabular figures.
    static let valueEmphasis = ZPDFTextStyle(baseSize: 14, weight: .semibold, face: .systemMonospacedDigits)

    /// The text inside a measurement label pill on the canvas ("Area: 620 SF").
    static let pillLabel = ZPDFTextStyle(baseSize: 12, weight: .semibold, face: .systemMonospacedDigits)

    /// Summary chip title in the ledger bar ("Areas", "Lengths").
    static let chipTitle = ZPDFTextStyle(baseSize: 11, weight: .regular, face: .system)

    /// Summary chip total in the ledger bar ("2,480 SF"). Tabular figures.
    static let chipValue = ZPDFTextStyle(baseSize: 12, weight: .medium, face: .systemMonospacedDigits)

    /// Avatar initials ("JD"), drawn on the accent fill.
    static let avatarInitials = ZPDFTextStyle(baseSize: 12, weight: .semibold, face: .system)
}

/// The Graphite Workshop type ramp.
///
/// AppKit has no Dynamic Type API as rich as UIKit's, but it does expose the user's preferred
/// text size through `NSFont.preferredFont(forTextStyle:)`. Every role scales by the ratio
/// between that preferred size and the ramp's own reference size, so the whole interface grows
/// with the system setting instead of ignoring it.
public enum ZPDFTypography {

    // MARK: - Roles

    public static let windowTitle = ZPDFTextStyle.windowTitle
    public static let sectionHeader = ZPDFTextStyle.sectionHeader
    public static let body = ZPDFTextStyle.body
    public static let control = ZPDFTextStyle.control
    public static let monoNumeric = ZPDFTextStyle.monoNumeric
    public static let monoNumericStrong = ZPDFTextStyle.monoNumericStrong
    public static let caption = ZPDFTextStyle.caption
    public static let code = ZPDFTextStyle.code
    public static let brandWordmark = ZPDFTextStyle.brandWordmark
    public static let brandTagline = ZPDFTextStyle.brandTagline
    public static let toolLabel = ZPDFTextStyle.toolLabel
    public static let toolLabelActive = ZPDFTextStyle.toolLabelActive
    public static let panelTitle = ZPDFTextStyle.panelTitle
    public static let tab = ZPDFTextStyle.tab
    public static let tabSelected = ZPDFTextStyle.tabSelected
    public static let cardTitle = ZPDFTextStyle.cardTitle
    public static let rowLabel = ZPDFTextStyle.rowLabel
    public static let valueEmphasis = ZPDFTextStyle.valueEmphasis
    public static let pillLabel = ZPDFTextStyle.pillLabel
    public static let chipTitle = ZPDFTextStyle.chipTitle
    public static let chipValue = ZPDFTextStyle.chipValue
    public static let avatarInitials = ZPDFTextStyle.avatarInitials

    /// Every role, for auditing and preview galleries.
    public static let allStyles: [(name: String, style: ZPDFTextStyle)] = [
        ("windowTitle", windowTitle),
        ("sectionHeader", sectionHeader),
        ("body", body),
        ("control", control),
        ("monoNumeric", monoNumeric),
        ("monoNumericStrong", monoNumericStrong),
        ("caption", caption),
        ("code", code),
        ("brandWordmark", brandWordmark),
        ("brandTagline", brandTagline),
        ("toolLabel", toolLabel),
        ("toolLabelActive", toolLabelActive),
        ("panelTitle", panelTitle),
        ("tab", tab),
        ("tabSelected", tabSelected),
        ("cardTitle", cardTitle),
        ("rowLabel", rowLabel),
        ("valueEmphasis", valueEmphasis),
        ("pillLabel", pillLabel),
        ("chipTitle", chipTitle),
        ("chipValue", chipValue),
        ("avatarInitials", avatarInitials)
    ]

    // MARK: - Dynamic Type

    /// The ramp's reference size: the point size `.body` has at the system default text size.
    public static let referenceBodySize: CGFloat = 13

    /// How far the user has scaled system text, clamped so a pro layout cannot collapse.
    ///
    /// Returns `1.0` at the default setting. Clamped to `0.85 ... 2.0`, which covers the
    /// 200% interface scaling requirement without letting a compact toolbar break apart.
    ///
    /// Read once per process (R-083): ``scaledSize(_:)`` runs for every font a view body builds,
    /// and it asked `NSFont.preferredFont(forTextStyle:)` each time. AppKit posts nothing when
    /// the preferred size changes, and a view body would not be re-evaluated for it anyway, so a
    /// new setting is picked up at the next launch — as it effectively was before.
    public static var dynamicTypeScale: CGFloat { cachedDynamicTypeScale }

    private static let cachedDynamicTypeScale: CGFloat = scale(forPreferredBodySize: NSFont.preferredFont(forTextStyle: .body).pointSize)

    /// The clamped ratio of a preferred body size to ``referenceBodySize``.
    static func scale(forPreferredBodySize preferred: CGFloat) -> CGFloat {
        guard preferred > 0, preferred.isFinite else { return 1 }
        return min(max(preferred / referenceBodySize, 0.85), 2.0)
    }

    /// The point size a role renders at right now.
    public static func scaledSize(_ style: ZPDFTextStyle) -> CGFloat {
        (style.baseSize * dynamicTypeScale).rounded()
    }

    // MARK: - Font construction

    /// The AppKit font for a role, already scaled for the user's text size setting.
    public static func nsFont(_ style: ZPDFTextStyle) -> NSFont {
        let size = scaledSize(style)
        switch style.face {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: style.nsWeight)
        case .systemMonospacedDigits:
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: style.nsWeight)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: style.nsWeight)
        }
    }

    /// The SwiftUI font for a role, already scaled for the user's text size setting.
    public static func font(_ style: ZPDFTextStyle) -> Font {
        let size = scaledSize(style)
        switch style.face {
        case .system:
            return Font.system(size: size, weight: style.swiftUIWeight, design: .default)
        case .systemMonospacedDigits:
            return Font.system(size: size, weight: style.swiftUIWeight, design: .default).monospacedDigit()
        case .monospaced:
            return Font.system(size: size, weight: style.swiftUIWeight, design: .monospaced)
        }
    }

    /// The line height a role occupies, for row metrics and list layout.
    public static func lineHeight(_ style: ZPDFTextStyle) -> CGFloat {
        let font = nsFont(style)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }
}

// MARK: - View sugar

public extension View {
    /// Applies a Graphite Workshop type role, including its tracking.
    func zpdfFont(_ style: ZPDFTextStyle) -> some View {
        font(ZPDFTypography.font(style)).tracking(style.tracking)
    }

    /// Applies a type role together with a semantic foreground token.
    func zpdfText(_ style: ZPDFTextStyle, _ token: ZPDFColorToken = .textPrimary) -> some View {
        zpdfFont(style).foregroundStyle(ZPDFColor.color(token))
    }
}
