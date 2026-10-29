import AppKit
import SwiftUI
import ZPDFDesignSystem

/// Hosts one SwiftUI panel inside an AppKit view controller.
///
/// `NSHostingController` would do most of this, but the shell needs the hosting *view* pinned
/// inside a plain `NSView` it owns: split view items, toolbar accessory rows and the detached
/// ledger window all want to set their own background, sizing behaviour and accessibility
/// identity around the SwiftUI content.
@MainActor
public final class ZPDFPanelHostViewController<Content: View>: NSViewController {

    private let rootView: Content
    /// The token the panel is painted in: the whole host when flush, the card when carded.
    public let backgroundToken: ZPDFColorToken
    private let panelAccessibilityLabel: String

    /// How the content is framed: edge to edge, or as a rounded card on the window ground.
    public let chrome: ZPDFPanelChrome

    /// The rounded card holding the content, when ``chrome`` is `.card`. `nil` for a flush host.
    private(set) var cardView: NSView?

    /// The hosting view holding the SwiftUI content.
    public private(set) var hostingView: NSHostingView<Content>!

    /// The panel's standard escape action. Escape always backs out one level, so every panel
    /// exposes a close the app tier can route Escape to.
    ///
    /// The SwiftUI content handles Escape itself through `onExitCommand` while it has key
    /// focus; this closure is the AppKit-level fallback that catches `cancelOperation` when
    /// focus sits on a non-SwiftUI subview inside the pane. Unset, Escape keeps travelling
    /// up the responder chain instead of being swallowed.
    public var onEscape: (@MainActor () -> Void)?

    /// Creates a host.
    ///
    /// - Parameters:
    ///   - accessibilityLabel: the panel's name, so VoiceOver's rotor can list it.
    ///   - background: the design-system token painted behind the SwiftUI content, which stops
    ///     a flash of window ground during live resize.
    ///   - chrome: `.flush` fills the host with `background`; `.card` paints the window ground
    ///     and stands the content on a rounded, hairline-bordered card filled with `background`.
    ///   - rootView: the SwiftUI panel.
    public init(
        accessibilityLabel: String,
        background: ZPDFColorToken = .surface,
        chrome: ZPDFPanelChrome = .flush,
        rootView: Content
    ) {
        self.rootView = rootView
        self.backgroundToken = background
        self.chrome = chrome
        self.panelAccessibilityLabel = accessibilityLabel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        // The shell builds its window in code; there is no nib to decode from.
        return nil
    }

    public override func loadView() {
        let container: NSView
        let contentParent: NSView
        switch chrome {
        case .flush:
            container = ZPDFPanelBackgroundView(token: backgroundToken)
            contentParent = container
        case .card(let cardInsets):
            // The host itself is window ground; the card on it carries the panel's colour.
            container = ZPDFPanelBackgroundView(token: ZPDFWindowChrome.groundToken)
            let card = ZPDFPanelCardView(fill: backgroundToken)
            card.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(card)
            // Trailing and bottom one notch under required: a split item collapsing to zero
            // passes through frames narrower than the insets, and an unsatisfiable card must
            // give way rather than fight the split for the pane's width.
            let trailing = card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -cardInsets.right)
            let bottom = card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -cardInsets.bottom)
            trailing.priority = .init(NSLayoutConstraint.Priority.required.rawValue - 1)
            bottom.priority = .init(NSLayoutConstraint.Priority.required.rawValue - 1)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: cardInsets.left),
                card.topAnchor.constraint(equalTo: container.topAnchor, constant: cardInsets.top),
                trailing,
                bottom
            ])
            cardView = card
            contentParent = card
        }
        container.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: rootView)
        // No sizing constraints from the SwiftUI content: every host of this class either
        // lives in a split view with explicit thickness limits or under an explicit height
        // anchor. The default `.standardBounds` publishes SwiftUI's minimum size as a
        // *required* AutoLayout constraint, and the panes' combined minimums (~700 pt for
        // the content row alone) beat the ledger divider maths — `setPosition` then
        // resolved the conflict by collapsing the docked ledger on every launch.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentParent.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentParent.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentParent.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentParent.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentParent.bottomAnchor)
        ])

        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(panelAccessibilityLabel)

        self.hostingView = hosting
        self.view = container
    }

    public override func cancelOperation(_ sender: Any?) {
        guard let onEscape else {
            // Not this panel's Escape to handle; let the chain keep looking.
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
            return
        }
        onEscape()
    }
}

/// A plain `NSView` that paints one design-system token and repaints when the appearance
/// changes, including the Increase Contrast variants.
final class ZPDFPanelBackgroundView: NSView {

    private let token: ZPDFColorToken

    init(token: ZPDFColorToken) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    nonisolated override var isFlipped: Bool { true }

    /// Without this AppKit never calls ``updateLayer()`` — it is consulted only when
    /// `wantsUpdateLayer` is `true`, and the default is `false` — so the view drew through the
    /// empty `draw(_:)`, the layer's background stayed `nil`, and every panel host, the layout
    /// root and the canvas backdrop were transparent (BH-298).
    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let variant = ZPDFAppearanceVariant.matching(effectiveAppearance)
        layer?.backgroundColor = ZPDFColor.nsColor(token, variant: variant).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
