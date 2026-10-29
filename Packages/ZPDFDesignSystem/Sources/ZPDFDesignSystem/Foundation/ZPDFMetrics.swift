import CoreGraphics
import SwiftUI

/// The spacing scale. Compact by design: Zenit packs a navigator, a canvas, an inspector and a
/// ledger into one window, so the ramp starts at 4pt and tops out at 24pt.
public enum ZPDFSpacing {
    /// 4pt — icon-to-label, inside a chip.
    public static let xs: CGFloat = 4
    /// 6pt — between sibling controls in a toolbar cluster.
    public static let s: CGFloat = 6
    /// 8pt — inspector row padding, list row inset.
    public static let m: CGFloat = 8
    /// 12pt — between inspector rows, panel content inset.
    public static let l: CGFloat = 12
    /// 16pt — between inspector sections.
    public static let xl: CGFloat = 16
    /// 24pt — empty-state and sheet padding.
    public static let xxl: CGFloat = 24

    /// The whole ramp, ascending.
    public static let ramp: [CGFloat] = [xs, s, m, l, xl, xxl]

    /// Control heights tuned to native macOS toolbar and inspector density.
    public enum Control {
        /// Unified toolbar band.
        public static let toolbarHeight: CGFloat = 38
        /// Square icon button in the main toolbar.
        public static let toolbarButton: CGFloat = 26
        /// Segmented control and popup button in a toolbar.
        public static let toolbarControl: CGFloat = 24
        /// Panel/inspector section header band.
        public static let panelHeader: CGFloat = 26
        /// One inspector row: label plus control.
        public static let inspectorRow: CGFloat = 24
        /// Text field, stepper and picker inside an inspector row.
        public static let inspectorControl: CGFloat = 20
        /// Bottom status bar band.
        public static let statusBar: CGFloat = 22
        /// Status pill height.
        public static let statusPill: CGFloat = 18
        /// Navigator / ledger list row.
        public static let listRow: CGFloat = 24

        /// Smallest square any interactive control may occupy, pointer or keyboard.
        public static let minimumHitTarget: CGFloat = 24
        /// Inline icon inside a control.
        public static let iconSmall: CGFloat = 12
        /// Standard toolbar and inspector icon.
        public static let icon: CGFloat = 16
        /// Emphasised icon: empty states, palettes.
        public static let iconLarge: CGFloat = 20
        /// Default label column width in the inspector, so controls line up across sections.
        public static let inspectorLabelWidth: CGFloat = 92
    }

    /// Main-window chrome measured from the 2026-09-23 mockup (1672 x 941 pt window).
    ///
    /// The mockup is denser at the top and roomier in the panels than the earlier control
    /// metrics above; those stay for the surfaces the mockup does not show (sheets, palettes).
    public enum Chrome {
        /// Top chrome band: brand row, tool group and the document tab strip under the brand.
        public static let topBarHeight: CGFloat = 88
        /// Icon-over-label tool button ("Select"): minimum width.
        public static let toolButtonWidth: CGFloat = 56
        /// Icon-over-label tool button: height.
        public static let toolButtonHeight: CGFloat = 60
        /// Glyph size inside an icon-over-label tool button.
        public static let toolIcon: CGFloat = 20
        /// Vertical gap between a tool glyph and its label.
        public static let toolIconLabelGap: CGFloat = 5
        /// Round author avatar in the top bar.
        public static let avatarLarge: CGFloat = 36
        /// Small avatar beside an author name in the inspector.
        public static let avatarSmall: CGFloat = 22
        /// Document tab height in the tab strip.
        public static let documentTabHeight: CGFloat = 34
        /// Canvas bar band (page navigation, zoom, undo/redo, document search).
        public static let canvasBarHeight: CGFloat = 48
        /// Buttons and fields inside the canvas bar and the ledger bar.
        public static let barControlHeight: CGFloat = 30
        /// Segmented tab control height (navigator, inspector, ledger tabs).
        public static let segmentedTabHeight: CGFloat = 36
        /// Height of the selected-tab indicator bar under a segmented tab.
        public static let tabIndicatorHeight: CGFloat = 2
        /// Rounded search field height.
        public static let searchFieldHeight: CGFloat = 30
        /// Thumbnail width inside a page card.
        public static let pageThumbnailWidth: CGFloat = 100
        /// Popup row and text field inside the inspector.
        public static let fieldHeight: CGFloat = 30
        /// Colour swatch button.
        public static let swatch: CGFloat = 28
        /// Square icon in an inspector header card.
        public static let headerCardIcon: CGFloat = 40
        /// Bottom ledger bar band, collapsed, hairlines included: 56 pt.
        public static let ledgerBarHeight: CGFloat = 56
        /// Summary chip in the ledger bar.
        public static let summaryChipHeight: CGFloat = 44
        /// Colour dot inside a popup row (layer, status).
        public static let statusDot: CGFloat = 10
        /// Gutter between the window's panels.
        public static let panelGutter: CGFloat = 8
        /// Inner padding of a panel.
        public static let panelPadding: CGFloat = 12
        /// Measurement label pill height on the canvas.
        public static let pillHeight: CGFloat = 24
    }
}

/// Corner radii. Small and consistent — Zenit reads as an instrument, not a consumer app.
public enum ZPDFRadius {
    /// 2pt — swatches, tiny indicators.
    public static let hairline: CGFloat = 2
    /// 3pt — text fields, inspector controls.
    public static let small: CGFloat = 3
    /// 5pt — toolbar buttons, segmented controls, pills.
    public static let medium: CGFloat = 5
    /// 8pt — panels, popovers, sheets.
    public static let large: CGFloat = 8
    /// 12pt — the loupe and other floating canvas chrome.
    public static let xLarge: CGFloat = 12
    /// Effectively a capsule.
    public static let pill: CGFloat = 999

    // MARK: 2026-09-23 mockup radii (semantic)

    /// 4pt — measurement label pills on the canvas, count badges, status dots' squares.
    public static let label: CGFloat = 4
    /// 6pt — buttons, tool chips, fields, popup rows, segmented segments, swatches.
    public static let control: CGFloat = 6
    /// 8pt — page cards, header cards, summary chips, document tabs (top corners).
    public static let card: CGFloat = 8
    /// 10pt — panels (navigator, canvas, inspector, ledger band) and the top bar's right group.
    public static let panel: CGFloat = 10
}

/// Line widths. Hairlines are display-scale aware so a 1px rule stays 1px on Retina.
public enum ZPDFStroke {
    /// 0.5pt — nominal hairline when display scale is unknown.
    public static let hairline: CGFloat = 0.5
    /// 1pt — control outlines, dividers on non-Retina.
    public static let regular: CGFloat = 1
    /// 1.5pt — selected control outline, emphasised divider.
    public static let emphasis: CGFloat = 1.5
    /// 2pt — keyboard focus ring.
    public static let focusRing: CGFloat = 2
    /// 1.6pt at 24pt icon size — the measurement icon stroke weight.
    public static let icon: CGFloat = 1.6
    /// 1.25pt — measurement geometry drawn over a page.
    public static let measurement: CGFloat = 1.25

    /// One device pixel at the given display scale.
    public static func devicePixel(displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? 1 / displayScale : hairline
    }
}
