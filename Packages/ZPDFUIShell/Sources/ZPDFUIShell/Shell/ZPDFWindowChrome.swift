import AppKit
import ZPDFDesignSystem

/// The project window's chrome geometry: one dark surface, panels standing on it as rounded cards.
///
/// The 2026-09-23 main-window mockup draws the window as a single navy ground — toolbar, tab
/// strip, the gaps between panels and the canvas backdrop are all one surface family — with the
/// Navigator and the Inspector as rounded, hairline-bordered cards on it and the Quantity Ledger
/// as a flush bar along the bottom. These are the numbers that composition is built from, in one
/// place, so the layout controller, the panel hosts and the split views cannot drift apart.
public enum ZPDFWindowChrome {

    /// The gap between the window edge and a card, and between two cards.
    ///
    /// Also the split dividers' thickness: the divider *is* the gap, painted in the window
    /// ground, so the space between two panels is the handle that resizes them. That makes
    /// the grab target eight points wide instead of one, which is the craft improvement over a
    /// hairline divider the mockup's gutters allow.
    ///
    /// 12 pt (the mockup's Navigator card ends at 270, the canvas starts
    /// at 285). `ZPDFSpacing.l`, one step above the 8 pt panel gutter design QA measured short.
    public static let gutter: CGFloat = ZPDFSpacing.l

    /// The corner radius of a panel card.
    public static let panelCornerRadius: CGFloat = ZPDFRadius.panel

    /// The ground every piece of chrome stands on.
    public static let groundToken: ZPDFColorToken = .background

    /// The fill of a panel card.
    public static let cardToken: ZPDFColorToken = .surface

    /// The rule under the top band and above the status strip.
    public static let hairlineToken: ZPDFColorToken = .border

    /// The edge of a panel card: a step stronger than a row hairline, so a card still reads as a
    /// card where its fill and the ground are close.
    public static let cardEdgeToken: ZPDFColorToken = .borderStrong
}

/// How a panel host frames its SwiftUI content.
public enum ZPDFPanelChrome: Equatable, Sendable {
    /// Edge to edge, painted in the host's own background token. The ledger bar, the canvas,
    /// the tab strip and the view modes use it.
    case flush
    /// A rounded, hairline-bordered card on the window ground, inset from the host's bounds.
    ///
    /// The insets are per edge because the split dividers already supply the gap *between*
    /// panes: a card inside a split only needs the gutter on the side facing the window edge.
    case card(insets: NSEdgeInsets)

    public static func == (lhs: ZPDFPanelChrome, rhs: ZPDFPanelChrome) -> Bool {
        switch (lhs, rhs) {
        case (.flush, .flush):
            return true
        case let (.card(a), .card(b)):
            return a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right
        default:
            return false
        }
    }
}

/// An `NSSplitView` whose divider is the chrome gutter: as wide as the gap between two cards and
/// painted in the window ground, so it reads as space rather than as a rule.
///
/// The divider stays a real divider — AppKit still draws the resize cursor over it, and the
/// layout controller's divider maths read `dividerThickness` rather than assuming one point.
@MainActor
public final class ZPDFChromeSplitView: NSSplitView {

    /// The gap the divider occupies: the window gutter.
    ///
    /// Read by AppKit from `dividerThickness`, which it also calls while computing a hosted
    /// SwiftUI view's safe area inside SwiftUI's own graph update. A main-actor isolation check
    /// executed there crashed the app at launch (EXC_BAD_ACCESS in `_checkExpectedExecutor`,
    /// crash reports 2026-09-23/24), so the getter is nonisolated. It reads a constant:
    /// the `nonisolated(unsafe)` storage and the public setter nobody called are gone (R-088).
    nonisolated private let gutter: CGFloat = ZPDFWindowChrome.gutter

    public nonisolated override var dividerThickness: CGFloat { gutter }

    public override var dividerColor: NSColor { ZPDFColor.nsColor(ZPDFWindowChrome.groundToken) }

    public override func drawDivider(in rect: NSRect) {
        // The ground, and nothing on it: the cards' own edges show where the panes end.
        dividerColor.setFill()
        rect.fill()
    }
}

/// A rounded, hairline-bordered card that repaints itself on every appearance change, including
/// the Increase Contrast variants.
///
/// Layer-backed and clipping, so SwiftUI content inside it is cut to the rounded corners rather
/// than squared off over them.
final class ZPDFPanelCardView: NSView {

    let fillToken: ZPDFColorToken
    let strokeToken: ZPDFColorToken

    init(fill: ZPDFColorToken, stroke: ZPDFColorToken = ZPDFWindowChrome.cardEdgeToken) {
        self.fillToken = fill
        self.strokeToken = stroke
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ZPDFWindowChrome.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    nonisolated override var isFlipped: Bool { true }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let variant = ZPDFAppearanceVariant.matching(effectiveAppearance)
        layer?.backgroundColor = ZPDFColor.nsColor(fillToken, variant: variant).cgColor
        layer?.borderColor = ZPDFColor.nsColor(strokeToken, variant: variant).cgColor
        // One device pixel, whatever the screen: a 1 pt border is two pixels on Retina and
        // reads as a rule, where the mockup draws a hairline.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.borderWidth = 1 / max(scale, 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
