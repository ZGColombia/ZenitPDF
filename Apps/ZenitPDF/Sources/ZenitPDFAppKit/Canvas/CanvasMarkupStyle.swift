import AppKit
import ZPDFDesignSystem

/// The canvas's markup appearance in one place: label pills, vertex handles, the selection
/// highlight, callout boxes and the live feedback inks, after the 2026-09-23 main-window design.
///
/// Everything here is drawn **on paper**. The page stays white in the dark appearance, so a
/// dynamic token that resolves to its dark value (a light cyan, a pale green) would put pale ink
/// on white. Canvas inks therefore resolve against the paper: the markup inks and the pill fill
/// are single-valued tokens, and the chrome tokens borrowed for the canvas (selection, snap,
/// calibration) are pinned to their light variant, or light high-contrast under Increase Contrast.
enum CanvasMarkupStyle {

    // MARK: - Label pills

    /// The pill's type: the design system's pill label — semibold with tabular digits, so a
    /// changing value does not jitter, and scaled with the user's text size.
    static var pillFont: NSFont { ZPDFTypography.nsFont(ZPDFTypography.pillLabel) }
    /// Horizontal padding inside a pill, per side, in view points: the shared pill geometry,
    /// so a canvas pill and a ``ZPDFPillLabel`` in a preview are the same shape.
    static let pillPaddingX: CGFloat = ZPDFPillGeometry.horizontalPadding
    /// The least vertical padding, for a text size so large the design height cannot hold it.
    static let pillPaddingY: CGFloat = ZPDFSpacing.xs
    /// The gap between an anchor and a pill hung beside it.
    static let pillAnchorGap: CGFloat = 8
    /// The gap between a length's shaft and the pill centred under it.
    static let lengthPillGap: CGFloat = 7
    /// The pill's corner radius: the design system's label radius.
    static let pillCornerRadius: CGFloat = ZPDFRadius.label

    /// The pill's outer size for a text of `size`: ``ZPDFPillGeometry``'s width rule and the
    /// design system's pill height, grown only when a large text size needs more.
    static func pillBoxSize(forText size: CGSize) -> CGSize {
        CGSize(
            width: ceil(size.width) + pillPaddingX * 2,
            height: max(ZPDFSpacing.Chrome.pillHeight, ceil(size.height) + pillPaddingY * 2)
        )
    }

    /// The text tone on a filled pill: light text on a dark fill, dark text on a light one,
    /// whichever reads better. The design's pills are white on blue; a markup drawn in yellow
    /// or light green keeps a legible label instead of white on yellow.
    enum PillTone: Hashable {
        case light
        case dark
    }

    static func pillTone(onFill fill: NSColor) -> PillTone {
        let ground = rgba(fill)
        let light = ZPDFColor.rgba(.textOnAccent, .dark)
        let dark = ZPDFColor.rgba(.textPrimary, .light)
        return light.contrastRatio(against: ground) >= dark.contrastRatio(against: ground) ? .light : .dark
    }

    static func pillTextColor(_ tone: PillTone) -> NSColor {
        switch tone {
        case .light: return ZPDFColor.nsColor(.textOnAccent, variant: .dark)
        case .dark: return ZPDFColor.nsColor(.textPrimary, variant: .light)
        }
    }

    /// The fill of a committed markup's pill: the markup's own colour, opaque, so the label
    /// reads as belonging to the ink it measures ("Area: 620 SF" in blue on a blue area).
    static func pillFill(forInk ink: NSColor) -> NSColor {
        (ink.usingColorSpace(.sRGB) ?? ink).withAlphaComponent(0.96)
    }

    /// The fill of the live readout pill: the default measurement ink.
    static var livePillFill: NSColor { ZPDFColor.nsColor(.pillFill) }

    // MARK: - Handles

    /// Every vertex handle: a 7 pt circle, paper-filled, ringed in the selection ink.
    static let handleDiameter: CGFloat = 7
    /// The ring round every handle.
    static let handleBorderWidth: CGFloat = 1.5
    /// The focused vertex handle — the one Delete removes (NL-MEASURE-06, T-001): filled with
    /// the selection ink instead of paper, and a little larger, so the cue is shape and size as
    /// well as colour.
    static let focusedHandleDiameter: CGFloat = 9
    /// A committed length's endpoint dot, drawn at rest in the markup's ink.
    static let endpointDotRadius: CGFloat = 3.5

    // MARK: - Selection

    /// How much wider than the markup's own stroke the selection halo is, in view points.
    static let selectionHaloExtraWidth: CGFloat = 6
    /// The halo's opacity: enough to read, faint enough that the ink stays on top.
    static let selectionHaloAlpha: CGFloat = 0.28

    // MARK: - Callouts

    /// The callout box's corner radius in view points, capped by the box so a small note stays
    /// a box rather than a lozenge.
    static func calloutCornerRadius(for box: CGRect) -> CGFloat {
        max(0, min(ZPDFRadius.control, min(box.width, box.height) / 4))
    }

    /// The backing a callout without a stored fill gets: paper, faintly tinted by its ink, so
    /// the note stays legible over dense linework (the design's callouts are pale boxes).
    static func calloutBacking(forInk ink: NSColor) -> NSColor {
        let tint = rgba(ink)
        let paper = rgba(Self.paper)
        let mixed = ZPDFRGBA(red: tint.red, green: tint.green, blue: tint.blue, alpha: 0.07).composited(over: paper)
        return NSColor(srgbRed: mixed.red, green: mixed.green, blue: mixed.blue, alpha: 0.94)
    }

    /// The least border a callout box and its leader are drawn with, in view points: the
    /// note's frame stays firm when its stored width is hairline or the zoom is far out
    /// (1.5 pt). A heavier stored width still wins.
    static let calloutMinimumBorder: CGFloat = ZPDFStroke.emphasis

    /// The padding between a callout's border and its text, in view points: 8 pt, shrunk on a
    /// box too small to spare it so the text still has room.
    static func calloutTextInset(for box: CGRect) -> CGFloat {
        max(2, min(ZPDFSpacing.m, min(box.width, box.height) * 0.18))
    }

    /// A callout's text: a deeper shade of its ink, so the words carry more weight than the
    /// frame round them (the design's callout text is darker than its border).
    static func calloutTextInk(forInk ink: NSColor) -> NSColor {
        let base = rgba(ink)
        let shade: CGFloat = 0.78
        return NSColor(
            srgbRed: base.red * shade,
            green: base.green * shade,
            blue: base.blue * shade,
            alpha: base.alpha
        )
    }

    // MARK: - Inks on paper

    /// The appearance the canvas's borrowed chrome tokens resolve in: always a paper variant.
    static var paperVariant: ZPDFAppearanceVariant {
        ZPDFAppearanceVariant.systemIncreaseContrastEnabled ? .lightHighContrast : .light
    }

    /// A chrome token resolved against the paper.
    static func onPaper(_ token: ZPDFColorToken) -> NSColor {
        ZPDFColor.nsColor(token, variant: paperVariant)
    }

    /// The sheet itself: the light surface, which is white.
    static var paper: NSColor { ZPDFColor.nsColor(.surface, variant: .light) }
    /// The measurement or markup being placed.
    static var liveInk: NSColor { ZPDFColor.nsColor(.inkBlue) }
    /// Selection halos, handles and the Select tool's rubber band.
    static var selectionInk: NSColor { onPaper(.selection) }
    /// The snap ring and the temporary tape.
    static var snapInk: NSColor { onPaper(.snapHighlight) }
    /// A calibration in progress.
    static var calibrationInk: NSColor { onPaper(.warning) }
    /// Search hits on the sheet.
    static var searchInk: NSColor { onPaper(.accentCyan) }

    static func rgba(_ color: NSColor) -> ZPDFRGBA {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return ZPDFRGBA(
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: srgb.alphaComponent
        )
    }
}
