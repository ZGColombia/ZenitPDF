import CoreGraphics
import SwiftUI
import ZPDFDesignSystem

/// The Navigator's visual vocabulary, in one place: which design-system token paints which part
/// of the 2026-09-23 mockup's left column.
///
/// Every colour here is a ``ZPDFColorToken`` with a dark and a light value (design round d1's
/// navy family) — the Navigator draws no literal colour of its own — so the light appearance and
/// Increase Contrast keep working. Tests read these values to pin the look ("the current page
/// card uses the accent border") without rendering a view.
enum NavigatorStyle {

    // MARK: Colours

    /// The ground the tab strip and the panel stand on: the window chrome.
    static let chromeFill: ZPDFColorToken = .background
    /// The rounded panel that holds the file header and the page cards, and the tab track.
    static let panelFill: ZPDFColorToken = .surface
    /// A raised surface: the card for the page on screen.
    static let raisedFill: ZPDFColorToken = .elevated
    /// The selected tab's fill.
    static let selectedTabFill: ZPDFColorToken = .selectedFill
    /// Hairlines between cards.
    static let hairline: ZPDFColorToken = .border
    /// The panel's and the tab track's edge.
    static let panelEdge: ZPDFColorToken = .borderStrong
    /// The filled accent: the wash on a card that is only in the Navigator's selection. Never a
    /// line — `accent` as a line is 2.79:1 on `surface` in dark, below the 3:1 that
    /// `ACCESSIBILITY_PLAN.md` sets for essential non-text controls.
    static let accent: ZPDFColorToken = .accent
    /// Every line that carries state: the current card's frame, a selected card's frame
    /// (4.27:1 on `elevated`, 5.04:1 on `surface`).
    static let stateLine: ZPDFColorToken = .accentBlue
    /// The accent as a foreground on chrome: the selected tab's underline, the unsaved dot.
    static let indicator: ZPDFColorToken = .accentBlue
    /// The translucent overlay under the pointer.
    static let hover: ZPDFColorToken = .stateHover
    /// The paper a page thumbnail is printed on. Pages are light in every appearance, like the
    /// canvas sheet — a PDF page is paper, not chrome — so this is the design system's one
    /// paper value (the ground its self-check measures the on-paper inks against).
    @MainActor static var paper: Color { ZPDFSelfCheck.paper.color }

    /// How strongly the accent washes a card that is only in the Navigator's selection.
    static let selectionTint: Double = 0.12

    // MARK: Geometry

    /// Gutter between the Navigator's edge, its tab strip and its panel.
    static let gutter: CGFloat = ZPDFSpacing.Chrome.panelGutter
    /// Corner radius of the panel.
    static let panelRadius: CGFloat = ZPDFRadius.panel
    /// Corner radius of a page card.
    static let cardRadius: CGFloat = ZPDFRadius.card
    /// Corner radius of a tab; the track adds its 2 pt inset.
    static let tabRadius: CGFloat = ZPDFRadius.control
    /// Height of the tab strip.
    static let tabHeight: CGFloat = ZPDFSpacing.Chrome.segmentedTabHeight
    /// Thickness of the selected tab's underline.
    static let tabUnderline: CGFloat = ZPDFSpacing.Chrome.tabIndicatorHeight
    /// Height of the file header row: a 28 pt row with its margins.
    static let fileHeaderHeight: CGFloat = 40
    /// The page card's minimum height (cards 250 × 104, pitch ~107).
    static let cardHeight: CGFloat = 104
    /// Inner padding of a page card (the thumbnail sits 12 pt from the card's top).
    static let cardPadding: CGFloat = 12
    /// The page card's thumbnail box (100 × 78). The sheet is fitted inside it at its own
    /// proportions, centred.
    static let thumbnailSize = CGSize(width: ZPDFSpacing.Chrome.pageThumbnailWidth, height: 78)
    /// The segment labels' size (~13 pt).
    static let segmentLabelSize: CGFloat = 13
    /// Border width of the card for the page on screen.
    static let currentBorder: CGFloat = 2
    /// Border width of a card that is only in the Navigator's selection.
    static let selectedBorder: CGFloat = 1

    // MARK: Motion

    /// Selection changes ride the design system's quick token, hover its micro token; both
    /// go through ``ZPDFMotion/animation(_:reduceMotion:)``, which turns them off under
    /// Reduce Motion.
    static let motion: ZPDFMotion.Token = .quick
}
